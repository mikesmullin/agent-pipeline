# pipeline/src/console.coffee
#
# Shared 24-bit ANSI console presentation for the agent loop:
#   • a bright PASTEL palette + helpers
#   • formatLogLine() — the colored structured log line `_G.log` emits
#     (dim timestamp · namespaced label with the STAGE word tinted · key=value
#      pairs with keys teal and values typed-colored)
#   • RunMeter — a live stderr `\r` status line (spinner + tick + elapsed +
#     activity›stage + queue depth + per-stage count·timing histogram)
#
# Pure presentation — no domain knowledge. Used by globals.coffee (_G.log) and
# loop.coffee (the multi-activity loop status line).

ESC = '\x1b['
export RESET = "#{ESC}0m"
export DIM   = "#{ESC}2m"
export BOLD  = "#{ESC}1m"
export rgb   = (r, g, b) -> "#{ESC}38;2;#{r};#{g};#{b}m"

# ── Pastel palette ───────────────────────────────────────────────────────────
export PAL =
  grey:   rgb 150, 152, 170
  slate:  rgb 116, 126, 150
  lav:    rgb 192, 170, 255
  sky:    rgb 130, 200, 255
  teal:   rgb 120, 225, 215
  mint:   rgb 150, 235, 185
  green:  rgb 130, 225, 150
  amber:  rgb 245, 200, 120
  peach:  rgb 250, 184, 152
  rose:   rgb 250, 152, 162
  red:    rgb 245, 122, 122
  pink:   rgb 245, 172, 225
  blue:   rgb 150, 182, 255
  yellow: rgb 240, 226, 142

_PASTELS = [PAL.lav, PAL.sky, PAL.teal, PAL.mint, PAL.amber, PAL.peach, PAL.pink, PAL.blue, PAL.green, PAL.yellow, PAL.rose]

# Deterministic pastel for an arbitrary token (stable color per activity/stage).
export pastelFor = (s) ->
  h = 0
  for ch in String(s ? '')
    h = (Math.imul(h, 31) + ch.charCodeAt(0)) | 0
  _PASTELS[Math.abs(h) % _PASTELS.length]

# Sentiment color for a log EVENT word (the last label segment).
_EVENT_COLOR =
  running: PAL.sky, start: PAL.sky, fetch: PAL.sky
  resolved: PAL.green, discovered: PAL.green, published: PAL.green
  narrated: PAL.green, pass: PAL.green, faithful: PAL.green, done: PAL.green
  judged: PAL.lav, verdict: PAL.lav
  stuck: PAL.amber, ambiguous: PAL.amber, deferred: PAL.amber, warn: PAL.amber
  skip: PAL.slate, missing: PAL.slate
  error: PAL.red, defect: PAL.red, failed: PAL.red, regression: PAL.rose
_eventColor = (ev) -> _EVENT_COLOR[ev] ? pastelFor(ev)

# Color a dotted label: `kibana.verify.running` → dim namespace · tinted stage ·
# sentiment-colored event.
export colorLabel = (label) ->
  segs = String(label ? '').split '.'
  if segs.length >= 3
    ns    = segs[0]
    mid   = segs[1...(segs.length - 1)].join '.'
    event = segs[segs.length - 1]
    "#{DIM}#{ns}.#{RESET}#{pastelFor mid}#{mid}#{DIM}.#{RESET}#{BOLD}#{_eventColor event}#{event}#{RESET}"
  else if segs.length is 2
    "#{pastelFor segs[0]}#{segs[0]}#{DIM}.#{RESET}#{BOLD}#{_eventColor segs[1]}#{segs[1]}#{RESET}"
  else
    "#{BOLD}#{pastelFor label}#{label}#{RESET}"

# Type-colored value.
_colorVal = (v) ->
  if v is null or v is undefined then "#{PAL.slate}#{v}#{RESET}"
  else switch typeof v
    when 'number'  then "#{PAL.amber}#{v}#{RESET}"
    when 'boolean' then "#{(if v then PAL.green else PAL.red)}#{v}#{RESET}"
    when 'string'  then "#{PAL.mint}#{JSON.stringify v}#{RESET}"
    else "#{PAL.peach}#{JSON.stringify v}#{RESET}"

# Build the full colored log line.
#   ts        — ISO timestamp string
#   label     — dotted event label
#   data      — { key: value } pairs (rendered key=value)
#   tag       — optional { text, color } activity chip, e.g. { text:'kibana', color:'#6366f1' }
export formatLogLine = (ts, label, data = {}, tag = null) ->
  chip = ''
  if tag?.text
    c = if tag.color then hexToAnsi(tag.color) else pastelFor(tag.text)
    chip = "#{c}#{tag.text}#{RESET} "
  pairs = (("#{PAL.teal}#{k}#{DIM}=#{RESET}#{_colorVal v}") for k, v of (data ? {}))
  body = if pairs.length then '  ' + pairs.join('  ') else ''
  "#{DIM}#{ts}#{RESET} #{chip}#{colorLabel label}#{body}"

# Hex (#rrggbb) → ANSI 24-bit fg.
export hexToAnsi = (hex) ->
  h = String(hex).replace /^#/, ''
  rgb parseInt(h[0...2], 16), parseInt(h[2...4], 16), parseInt(h[4...6], 16)

# ── duration / spinner ───────────────────────────────────────────────────────
SPIN = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏']

export dur = (ms) ->
  ms = 0 unless ms? and isFinite ms
  return "#{Math.round ms}ms" if ms < 1000
  s = ms / 1000
  return "#{s.toFixed 1}s" if s < 60
  m = Math.floor s / 60
  return "#{m}m #{Math.round(s % 60)}s" if m < 60
  h = Math.floor m / 60
  "#{h}h #{m % 60}m"

# ── RunMeter: the live loop status line ──────────────────────────────────────
# Reads a shared `stats` object (mutated by the loop) and repaints a single
# stderr line. Coexists with the scrolling stdout log: callers invoke clear()
# right before emitting a log line; the interval repaint restores the bar.
export class RunMeter
  constructor: (@stats, @stageNames = []) ->
    @frame = 0
    @tty = !!process.stderr.isTTY
    @timer = null
    @visible = false

  start: ->
    return unless @tty
    @timer = setInterval (=> @render()), 110
    @timer?.unref?()

  clear: ->
    return unless @tty and @visible
    process.stderr.write "\r#{ESC}2K"
    @visible = false

  stop: ->
    clearInterval @timer if @timer
    @timer = null
    @clear()

  render: ->
    return unless @tty
    s = @stats ? {}
    @frame = (@frame + 1) % SPIN.length
    cols = process.stderr.columns or 100
    elapsed = dur(Date.now() - (s.startedAt or Date.now()))
    sp = "#{PAL.sky}#{SPIN[@frame]}#{RESET}"

    parts = []
    parts.push "#{sp} #{BOLD}tick #{PAL.amber}#{s.tick ? 0}#{RESET}"
    parts.push "#{PAL.grey}#{elapsed}#{RESET}"
    loc = "#{pastelFor s.activity}#{s.activity or '—'}#{RESET}"
    loc += "#{DIM}›#{RESET}#{BOLD}#{pastelFor s.stage}#{(s.stage or '').replace(/System$/, '')}#{RESET}" if s.stage
    parts.push loc
    parts.push "#{PAL.teal}#{s.total ? 0}#{RESET}#{DIM} on disk#{RESET}"
    parts.push "#{DIM}+#{RESET}#{PAL.peach}#{s.remaining}#{RESET}#{DIM} queued#{RESET}" if s.remaining?

    # per-stage count·timing histogram
    seg = []
    for name in @stageNames
      short = name.replace /System$/, ''
      n  = s.stageCounts?[name]
      ms = s.stageMs?[name]
      next = "#{pastelFor name}#{short}#{RESET}"
      if n? then next += " #{PAL.amber}#{n}#{RESET}"
      if ms? then next += "#{DIM}·#{RESET}#{PAL.slate}#{dur ms}#{RESET}"
      seg.push next if n? or ms?
    parts.push seg.join("#{DIM} #{RESET}") if seg.length

    line = parts.join "#{DIM} · #{RESET}"
    # rough truncation to terminal width (ANSI-aware-ish: strip codes for length)
    plainLen = line.replace(/\x1b\[[0-9;]*m/g, '').length
    if plainLen > cols - 1
      # trim trailing segments until it fits
      while parts.length > 3 and line.replace(/\x1b\[[0-9;]*m/g, '').length > cols - 2
        parts.pop()
        line = parts.join("#{DIM} · #{RESET}") + "#{DIM} …#{RESET}"
    process.stderr.write "\r#{ESC}2K#{line}"
    @visible = true

export default { PAL, RESET, DIM, BOLD, rgb, pastelFor, colorLabel, formatLogLine, hexToAnsi, dur, RunMeter }
