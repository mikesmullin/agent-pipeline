# pipeline/src/walk.coffee
#
# runWalk — the generalized "walk a selection of entities through a selection of
# stages" dev/debug harness (formerly each project's hand-rolled `--entity X
# --stage Y` F4 block). Promoted into the framework so every pipeline AND the
# `pipeline walk` CLI share ONE polished implementation.
#
# Capability (the whole point):
#   • entity selection: a single entity, an explicit list, or a range
#   • stage  selection: a single stage,  an explicit list, or a range
#   • optional activity glob (multi-activity projects)
#   • runs one entity at a time (streaming → bounded memory, no bulk init), so
#     it is safe to walk thousands of entities
#   • a live stderr status line (24-bit color): braille spinner + gradient
#     progress bar + current/processed/remaining counts + last/mean time + ETA
#   • single-entity walks print the rich gate-trace + component-diff (classic F4)
#
# Selection grammar (all optional; omitting a selector = "everything"):
#   --entity   <id>                 one entity
#   --entities <id1,id2,...>        explicit list
#   --entities <idA>..<idB>         inclusive range over the sorted id list
#   --entities <n>..<m>             inclusive 0-based index range into that list
#   --entities <n>..  | ..<m> | ..  open-ended range (head / tail / all)
#   --stage    <name>               one stage
#   --stages   <a,b,c>              explicit list (always run in pipeline order)
#   --stages   <a>..<c>             inclusive pipeline-order slice (open ends ok)
#   --activity <glob>               limit to activities matching (* wildcard)
#   --once                          no selectors → whole pipeline, all entities
#   --verbose                       per-entity ✓/diff lines even in batch mode
#   --no-progress                   disable the live status line (plain logs)
#   --json                          machine-readable summary on stdout
#   --limit <n>                     cap the number of entities walked
#
# Stage tokens match leniently: 'findDataviewSystem', 'find-dataview', and
# 'findDataview' all resolve to the same step.
import { readdirSync } from 'fs'
import { _G } from './globals.coffee'
import './world.coffee'
import './entity.coffee'
import { Activities } from './activities.coffee'

# ── 24-bit ANSI palette ──────────────────────────────────────────────────────
ESC   = '\x1b['
RESET = "#{ESC}0m"
DIM   = "#{ESC}2m"
BOLD  = "#{ESC}1m"
rgb   = (r, g, b) -> "#{ESC}38;2;#{r};#{g};#{b}m"
CYAN  = rgb 80, 200, 235
GREEN = rgb 95, 205, 120
RED   = rgb 235, 95, 95
YELL  = rgb 225, 185, 60
GREY  = rgb 140, 140, 150

SPIN = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏']

_clamp = (n, lo, hi) -> Math.max lo, Math.min hi, n

# Human-friendly duration.
_dur = (ms) ->
  ms = 0 unless ms? and isFinite ms
  return "#{Math.round ms}ms" if ms < 1000
  s = ms / 1000
  return "#{s.toFixed 1}s" if s < 60
  m = Math.floor s / 60
  rem = Math.round s % 60
  return "#{m}m #{rem}s" if m < 60
  h = Math.floor m / 60
  "#{h}h #{m % 60}m"

_lerp = (a, b, t) -> Math.round a + (b - a) * t

# Cyan→green gradient fill bar.
_bar = (frac, width) ->
  frac = _clamp frac, 0, 1
  filled = Math.round frac * width
  out = ''
  for i in [0...width]
    if i < filled
      t = if width > 1 then i / (width - 1) else 0
      out += "#{rgb _lerp(80, 95, t), _lerp(200, 205, t), _lerp(235, 120, t)}█"
    else
      out += "#{GREY}░"
  "#{out}#{RESET}"

# ── Live progress meter (stderr status line) ─────────────────────────────────
class ProgressMeter
  constructor: (@total, @label) ->
    @done = 0
    @startedAt = Date.now()
    @lastMs = 0
    @sumMs = 0
    @minMs = Infinity
    @maxMs = 0
    @errors = 0
    @current = null
    @frame = 0
    @tty = !!process.stderr.isTTY
    @timer = null
    @lastPlain = 0

  start: ->
    return unless @tty
    @timer = setInterval (=> @render()), 90
    @timer?.unref?()

  setCurrent: (id) ->
    @current = id
    @render() if @tty

  tick: (id, ms, errored) ->
    @done += 1
    @current = id
    @lastMs = ms
    @sumMs += ms
    @minMs = Math.min @minMs, ms
    @maxMs = Math.max @maxMs, ms
    @errors += 1 if errored
    if @tty then @render() else @renderPlain()

  meanMs: -> if @done then @sumMs / @done else 0
  etaMs:  -> Math.max(0, @total - @done) * @meanMs()

  render: ->
    return unless @tty
    @frame = (@frame + 1) % SPIN.length
    cols = process.stderr.columns or 80
    frac = if @total then @done / @total else 0
    pct  = Math.round frac * 100
    pad  = String(@total).length
    doneStr = String(@done).padStart pad, '0'
    sp = "#{CYAN}#{SPIN[@frame]}#{RESET}"
    head = "#{sp} #{BOLD}#{@label}#{RESET} #{doneStr}/#{@total}"
    parts = [head]
    if cols >= 70
      barW = _clamp cols - 62, 8, 28
      parts.push "#{DIM}▕#{RESET}#{_bar frac, barW}#{DIM}▏#{RESET}"
    parts.push "#{frac and GREEN or ''}#{pct}%#{RESET}"
    cur = if @current? then "#{@current}" else '—'
    parts.push "#{GREY}cur#{RESET} #{cur}"
    parts.push "#{GREY}last#{RESET} #{_dur @lastMs}"
    parts.push "#{GREY}mean#{RESET} #{_dur @meanMs()}"
    parts.push "#{GREY}eta#{RESET} #{_dur @etaMs()}"
    parts.push "#{RED}err #{@errors}#{RESET}" if @errors
    line = parts.join "#{DIM} · #{RESET}"
    process.stderr.write "\r#{ESC}2K#{line}"

  renderPlain: ->
    # Non-TTY: emit a progress line at ~5% steps (and always on the last one).
    step = Math.max 1, Math.floor(@total / 20)
    return unless @done is @total or (@done - @lastPlain) >= step
    @lastPlain = @done
    pct = if @total then Math.round(@done / @total * 100) else 100
    process.stderr.write "  #{@label} #{@done}/#{@total} (#{pct}%) last #{_dur @lastMs} mean #{_dur @meanMs()} eta #{_dur @etaMs()}\n"

  stop: ->
    clearInterval @timer if @timer
    @timer = null
    process.stderr.write "\r#{ESC}2K" if @tty

# ── selector parsing ─────────────────────────────────────────────────────────
_globToRegExp = (pattern) ->
  escaped = pattern.replace /[-/\\^$+?.()|[\]{}]/g, '\\$&'
  new RegExp '^' + escaped.replace(/\*/g, '.*') + '$'

# Canonicalize a stage token for lenient matching:
#   'findDataviewSystem' / 'find-dataview' / 'findDataview' → 'finddataview'
_canonStage = (s) ->
  String(s).replace(/System$/, '').replace(/[^a-zA-Z0-9]/g, '').toLowerCase()

_parseArgs = (argv) ->
  out =
    entitySpec: null        # { kind:'single'|'list'|'range'|'all', ... }
    stageSpec:  null        # { kind:'single'|'list'|'range', ... } or null = all
    activity:   null
    once:       false
    verbose:    false
    progress:   true
    json:       false
    limit:      null
  take = (i) -> argv[i + 1]
  i = 0
  while i < argv.length
    a = argv[i]
    switch a
      when '--entity'
        out.entitySpec = { kind: 'single', id: take(i) }; i += 2
      when '--entities'
        out.entitySpec = _parseEntitySpec take(i); i += 2
      when '--stage'
        out.stageSpec = { kind: 'single', token: take(i) }; i += 2
      when '--stages'
        out.stageSpec = _parseStageSpec take(i); i += 2
      when '--activity'
        out.activity = take(i); i += 2
      when '--limit'
        out.limit = parseInt(take(i), 10); i += 2
      when '--once'           then out.once = true; i += 1
      when '--verbose', '-v'  then out.verbose = true; i += 1
      when '--no-progress'    then out.progress = false; i += 1
      when '--json'           then out.json = true; out.progress = false; i += 1
      else
        # Unknown flag → ignore unknown options, but a bare value is an error.
        if a?.startsWith '--' then i += 1 else throw new Error "walk: unexpected argument '#{a}'"
  out

_parseEntitySpec = (spec) ->
  throw new Error '--entities requires a value' unless spec
  return { kind: 'list', ids: (s.trim() for s in spec.split(',') when s.trim()) } if spec.includes ','
  if spec.includes '..'
    [lo, hi] = spec.split '..'
    return { kind: 'range', lo: lo?.trim() or '', hi: hi?.trim() or '' }
  { kind: 'list', ids: [spec.trim()] }

_parseStageSpec = (spec) ->
  throw new Error '--stages requires a value' unless spec
  return { kind: 'list', tokens: (s.trim() for s in spec.split(',') when s.trim()) } if spec.includes ','
  if spec.includes '..'
    [lo, hi] = spec.split '..'
    return { kind: 'range', lo: lo?.trim() or '', hi: hi?.trim() or '' }
  { kind: 'single', token: spec.trim() }

# ── resolution ───────────────────────────────────────────────────────────────
# Sorted entity ids present on disk for an activity (no bulk load).
_listIds = (dir) ->
  try
    (f.slice(0, -5) for f in readdirSync(dir) when f.endsWith '.yaml').sort()
  catch
    []

# Resolve a stage selector against an activity's ordered pipeline ([{name,fn}]).
_selectSteps = (pipeline, spec) ->
  return pipeline.slice() unless spec?
  idxOf = (token) ->
    canon = _canonStage token
    pipeline.findIndex (s) -> _canonStage(s.name) is canon
  switch spec.kind
    when 'single'
      i = idxOf spec.token
      if i < 0 then [] else [pipeline[i]]
    when 'list'
      wanted = new Set(_canonStage(t) for t in spec.tokens)
      pipeline.filter (s) -> wanted.has _canonStage(s.name)   # keep pipeline order
    when 'range'
      lo = if spec.lo then idxOf spec.lo else 0
      hi = if spec.hi then idxOf spec.hi else pipeline.length - 1
      return [] if lo < 0 or hi < 0
      [lo, hi] = [hi, lo] if lo > hi
      pipeline.slice lo, hi + 1
    else pipeline.slice()

# Resolve an entity selector against an activity's sorted on-disk id list.
_selectIds = (existing, spec) ->
  return existing.slice() unless spec? and spec.kind isnt 'all'
  present = new Set existing
  switch spec.kind
    when 'single'
      if present.has spec.id then [spec.id] else []
    when 'list'
      spec.ids.filter (id) -> present.has id
    when 'range'
      loN = if spec.lo is '' then NaN else Number spec.lo
      hiN = if spec.hi is '' then NaN else Number spec.hi
      bothNumeric = (spec.lo is '' or Number.isInteger loN) and (spec.hi is '' or Number.isInteger hiN) and (spec.lo isnt '' or spec.hi isnt '')
      if bothNumeric
        lo = if spec.lo is '' then 0 else loN
        hi = if spec.hi is '' then existing.length - 1 else hiN
        [lo, hi] = [hi, lo] if lo > hi
        existing.slice Math.max(0, lo), hi + 1
      else
        loI = if spec.lo is '' then 0 else existing.indexOf spec.lo
        hiI = if spec.hi is '' then existing.length - 1 else existing.indexOf spec.hi
        return [] if loI < 0 or hiI < 0
        [loI, hiI] = [hiI, loI] if loI > hiI
        existing.slice loI, hiI + 1
    else existing.slice()

# ── snapshot / diff helpers ──────────────────────────────────────────────────
_snap = (activityId, id) ->
  e = _G.World.for(activityId).get id
  return null unless e
  { _mtime, _path, _full, _projected, _exists, rest... } = e
  JSON.parse JSON.stringify rest

_changedKeys = (before, after) ->
  keys = [...new Set([...Object.keys(before ? {}), ...Object.keys(after ? {})])].sort()
  keys.filter (k) -> JSON.stringify(before?[k]) isnt JSON.stringify(after?[k])

# ── the walk ─────────────────────────────────────────────────────────────────
export runWalk = (opts = {}) ->
  argv            = opts.argv ? process.argv.slice(2)
  fallbackSystems = opts.systems ? null        # single-activity config projects

  flags = _parseArgs argv
  await Activities.loadAll()

  # Which activities?
  acts = Activities.all()
  if flags.activity?
    re = _globToRegExp flags.activity
    acts = acts.filter (a) -> re.test a.id
    if acts.length is 0
      process.stderr.write "#{RED}walk: --activity '#{flags.activity}' matched no activities#{RESET}\n"
      return { walked: 0, errors: 1 }

  # Build the worklist: per activity, the ordered steps × the selected ids.
  worklist = []
  stageMiss = false
  for a in acts
    pipeline = if a.pipeline?.length then a.pipeline else (fallbackSystems ? [])
    continue if pipeline.length is 0
    steps = _selectSteps pipeline, flags.stageSpec
    if flags.stageSpec? and steps.length is 0
      stageMiss = true
      continue
    ids = _selectIds _listIds(a.entityDir), flags.entitySpec
    continue if ids.length is 0
    worklist.push { activity: a, steps, ids }

  if flags.stageSpec? and worklist.length is 0 and stageMiss
    process.stderr.write "#{RED}walk: no stage matched that selector#{RESET}\n"
    return { walked: 0, errors: 1 }

  # Apply a global --limit across the worklist.
  total = worklist.reduce ((n, w) -> n + w.ids.length), 0
  if flags.limit? and flags.limit < total
    remaining = flags.limit
    for w in worklist
      if w.ids.length > remaining
        w.ids = w.ids.slice 0, Math.max(0, remaining)
      remaining -= w.ids.length
    worklist = worklist.filter (w) -> w.ids.length > 0
    total = flags.limit

  if total is 0
    process.stderr.write "#{YELL}walk: matched 0 entities#{RESET} #{DIM}(check your --entity/--entities/--activity selectors)#{RESET}\n"
    return { walked: 0, errors: 0 }

  stageNames = []
  _seenStage = new Set()
  for w in worklist
    for s in w.steps when not _seenStage.has(s.name)
      _seenStage.add s.name
      stageNames.push s.name
  richSingle = total is 1 and not flags.json

  # Header (skip in --json mode).
  unless flags.json
    actLabel = if worklist.length is 1 then worklist[0].activity.id else "#{worklist.length} activities"
    process.stderr.write "#{BOLD}#{CYAN}▶ walk#{RESET} #{DIM}#{total} #{if total is 1 then 'entity' else 'entities'} · #{stageNames.length} #{if stageNames.length is 1 then 'stage' else 'stages'} · #{actLabel}#{RESET}\n"

  # Save / restore globals the walk perturbs.
  prevOnly = _G.onlyEntity
  prevIdx  = _G.useFieldIndex
  _G.useFieldIndex = false   # debug walk always uses full bodies

  meter = null
  if flags.progress and not richSingle and not flags.json
    meter = new ProgressMeter total, (if worklist.length is 1 then worklist[0].activity.id else 'walk')
    meter.start()

  runInActivity = (activityId, fn) ->
    _G.withActivity activityId, fn

  stats =
    walked: 0
    errors: 0
    changedEntities: 0
    perEntity: []
    byStageErrors: {}

  interrupted = false
  onSigint = ->
    interrupted = true
    _G.quit = true
  process.on 'SIGINT', onSigint

  for { activity, steps, ids } in worklist
    break if interrupted
    for id in ids
      break if interrupted
      _G.onlyEntity = id
      await _G.Entity.load activity.id, id
      before = _snap activity.id, id
      gateStart = _G.gateLog?.length ? 0
      meter?.setCurrent id
      t0 = Date.now()
      entErr = 0
      stageRows = []
      await runInActivity activity.id, ->
        for step in steps
          break if interrupted
          _G.currentSystem = step.name
          s0 = Date.now()
          try
            await step.fn()
            stageRows.push { name: step.name, ms: Date.now() - s0, ok: true }
          catch err
            entErr += 1
            stats.byStageErrors[step.name] = (stats.byStageErrors[step.name] ? 0) + 1
            stageRows.push { name: step.name, ms: Date.now() - s0, ok: false, err }
            unless meter?
              process.stderr.write "#{RED}✗ #{activity.id}/#{step.name}#{RESET} #{DIM}(#{id})#{RESET} #{err?.message or err}\n"
      elapsed = Date.now() - t0
      after = _snap activity.id, id
      changed = _changedKeys before, after
      stats.walked += 1
      stats.errors += entErr
      stats.changedEntities += 1 if changed.length > 0
      stats.perEntity.push { activity: activity.id, id, ms: elapsed, changed, errors: entErr }

      if richSingle
        _printRich activity.id, id, steps, stageRows, before, after, gateStart
      else if flags.verbose and not flags.json
        mark = if entErr then "#{RED}✗#{RESET}" else "#{GREEN}✓#{RESET}"
        chg = if changed.length then "#{GREY}Δ #{changed.join ','}#{RESET}" else "#{DIM}(no change)#{RESET}"
        # Don't fight the live meter: write a clean line then let it redraw.
        meter?.stop()
        process.stderr.write "#{mark} #{activity.id}/#{id} #{DIM}#{_dur elapsed}#{RESET} #{chg}\n"
        meter?.start()

      meter?.tick id, elapsed, entErr > 0
      _G.Entity.evict activity.id, id

  meter?.stop()
  process.removeListener 'SIGINT', onSigint
  _G.onlyEntity = prevOnly
  _G.useFieldIndex = prevIdx

  result = _summarize stats, worklist, stageNames, flags, interrupted
  result

# Rich single-entity output (the classic F4 walk: per-stage ✓, gate trace, diff).
_printRich = (activityId, id, steps, stageRows, before, after, gateStart) ->
  for row in stageRows
    if row.ok
      process.stdout.write "#{GREEN}✓#{RESET} #{activityId}/#{row.name} #{DIM}#{_dur row.ms}#{RESET}\n"
    else
      process.stdout.write "#{RED}✗ #{activityId}/#{row.name}#{RESET} #{(row.err?.stack or row.err)}\n"
  trace = (_G.gateLog ? []).slice(gateStart).filter (g) -> String(g.entity) is String(id)
  if trace.length
    process.stdout.write "\n#{BOLD}gate trace#{RESET} #{DIM}(#{id})#{RESET}\n"
    for g in trace
      mark = if g.passed then "#{GREEN}✓#{RESET}" else "#{RED}✗#{RESET}"
      process.stdout.write "  #{mark} #{DIM}#{g.system ? ''}#{RESET} #{g.label ? ''}\n"
  changed = _changedKeys before, after
  process.stdout.write "\n#{BOLD}component diff#{RESET} #{DIM}(#{id} @ #{activityId})#{RESET}\n"
  if changed.length is 0
    process.stdout.write "  #{DIM}(no component changes)#{RESET}\n"
  else
    for k in changed
      tag = if not before?[k]? then "#{GREEN}+#{RESET}" else if not after?[k]? then "#{RED}-#{RESET}" else "#{CYAN}~#{RESET}"
      process.stdout.write "  #{tag} #{k}\n"

_summarize = (stats, worklist, stageNames, flags, interrupted) ->
  durations = (p.ms for p in stats.perEntity)
  minMs = if durations.length then Math.min(durations...) else 0
  maxMs = if durations.length then Math.max(durations...) else 0
  meanMs = if durations.length then (durations.reduce ((a, b) -> a + b), 0) / durations.length else 0
  totalMs = durations.reduce ((a, b) -> a + b), 0
  result =
    walked:  stats.walked
    errors:  stats.errors
    changed: stats.changedEntities
    stages:  stageNames
    activities: (w.activity.id for w in worklist)
    timing:  { minMs, meanMs, maxMs, totalMs }
    interrupted: interrupted

  if flags.json
    process.stdout.write JSON.stringify(result) + '\n'
    return result

  # Skip the heavy summary for a single rich walk (its detail already printed).
  return result if stats.walked is 1

  mark = if stats.errors then "#{YELL}⚠#{RESET}" else "#{GREEN}✓#{RESET}"
  head = "#{mark} walked #{BOLD}#{stats.walked}#{RESET} #{if stats.walked is 1 then 'entity' else 'entities'} through #{stageNames.length} #{if stageNames.length is 1 then 'stage' else 'stages'} in #{_dur totalMs}"
  head += " #{YELL}(interrupted)#{RESET}" if interrupted
  process.stderr.write "\n#{head}\n"
  process.stderr.write "  #{GREY}timing#{RESET}  min #{_dur minMs} #{DIM}·#{RESET} mean #{_dur meanMs} #{DIM}·#{RESET} max #{_dur maxMs}\n"
  process.stderr.write "  #{GREY}changed#{RESET} #{stats.changedEntities} #{DIM}entities wrote ≥1 component#{RESET}\n"
  if stats.errors
    detail = ("#{n}×#{name}" for name, n of stats.byStageErrors).join '  '
    process.stderr.write "  #{RED}errors#{RESET}  #{stats.errors} #{DIM}#{detail}#{RESET}\n"
  result

export default runWalk
