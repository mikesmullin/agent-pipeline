# pipeline/src/telemetry.coffee — lightweight, PERF-gated performance tracing.
#
# Promoted from a per-project lib so every pipeline shares one implementation.
# It is OPT-IN and OFF by default: nothing is measured or printed unless the
# `PERF` env var is set (and not '0'), so production runs pay nothing.
#
# Traces:    Telemetry.startTimer(label) → stop fn. Calling stop() accumulates
#            <activity>.<label>.{ms,count} and (when PERF) logs a perf.timer line.
# Counters:  Telemetry.inc(key, n = 1) — increment an arbitrary named counter.
# Reporting: Telemetry.report() — print all counters grouped by activity; timer
#            pairs (.ms + .count) merge into one line with avg latency.
# Reset:     Telemetry.reset() — clear counters (call right after report()).
#
# Counters are auto-prefixed with the current activity id (from the framework's
# activity context, `_G.currentActivity()`), so parallel activities stay isolated.
#
# Loop usage (the framework loop does this for you):
#   t = Telemetry.startTimer "stage.#{name}" ; await step.fn() ; t()
#   …then once per tick:  Telemetry.report() ; Telemetry.reset()
import { _G } from './globals.coffee'

_perfEnabled = -> !!process.env.PERF and process.env.PERF isnt '0'

_counters = {}

_prefix = ->
  act = _G.currentActivity?()
  if act then "#{act}." else ''

export Telemetry =
  # Whether tracing is active (env PERF set). Systems can cheaply skip work.
  enabled: _perfEnabled

  # Start a named latency timer. Returns a stop function that, when called,
  # accumulates <activity>.<label>.{ms,count} (+ logs perf.timer when PERF).
  startTimer: (label) ->
    t0 = Date.now()
    pf = _prefix()
    ->
      ms = Date.now() - t0
      _G.log 'perf.timer', { label, ms } if _perfEnabled()
      k = "#{pf}#{label}"
      _counters["#{k}.ms"]    = (_counters["#{k}.ms"]    or 0) + ms
      _counters["#{k}.count"] = (_counters["#{k}.count"] or 0) + 1
      ms

  # Increment a named counter, prefixed with the current activity id.
  inc: (key, n = 1) ->
    k = "#{_prefix()}#{key}"
    _counters[k] = (_counters[k] or 0) + n

  # Print all accumulated counters to stdout, grouped by activity. Timer pairs
  # (label.ms + label.count) merge into one line with an avg. No-op unless PERF
  # is set and at least one counter exists.
  report: ->
    return unless _perfEnabled() and Object.keys(_counters).length > 0

    byAct = {}
    for own k, v of _counters
      dot  = k.indexOf '.'
      act  = if dot >= 0 then k[0...dot] else '_global'
      rest = if dot >= 0 then k[dot+1..] else k
      byAct[act] ?= {}
      byAct[act][rest] = v

    lines = ['[perf.report]']
    for act in Object.keys(byAct).sort()
      lines.push "  #{act}:"
      metr    = byAct[act]
      emitted = new Set()
      for k in Object.keys(metr).sort()
        continue if emitted.has k
        if k.endsWith '.ms'
          base   = k[0...-3]
          cntKey = "#{base}.count"
          cnt    = metr[cntKey] or 1
          avg    = Math.round metr[k] / cnt
          lines.push "    #{(base + ':').padEnd 38}  #{String(cnt).padStart 4}x  total #{metr[k]}ms  avg #{avg}ms"
          emitted.add cntKey
        else
          lines.push "    #{(k + ':').padEnd 38}  #{metr[k]}"
    console.log lines.join '\n'

  # Clear all counters. Call immediately after report().
  reset: ->
    _counters = {}

export default Telemetry
