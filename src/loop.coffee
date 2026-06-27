# pipeline/src/loop.coffee
#
# The engine tick. `runPipeline()` is the one entry point a project's
# agent.coffee calls. It:
#   - loads config.yaml and configures _G
#   - dynamically imports each system from systems/<name>.coffee
#   - mirrors stdout/stderr into debug.log; guards against a double-run via a PID file
#   - hot-reloads systems/ and microagents/ on edit (no restart)
#   - initializes the Entity model (loads db/, starts the chokidar watcher)
#   - runs systems in weight order forever, printing a per-tick status summary
#
# Everything in the loop body is a system call — that is the standard.
import Agent from 'agl-ai'
import { readFile, writeFile, unlink } from 'fs/promises'
import { resolve, basename } from 'path'
import { createWriteStream } from 'fs'
import chokidar from 'chokidar'
import { _G } from './globals.coffee'
import './world.coffee'
import './entity.coffee'
import { Activities } from './activities.coffee'
import { loadConfig } from './config.coffee'
import { runWalk } from './walk.coffee'
import { Telemetry } from './telemetry.coffee'

_ts = -> new Date().toLocaleTimeString('en-US', { hour12: false })
_DIM = '\x1b[2m'; _RST = '\x1b[0m'; _GRN = '\x1b[32m'; _RED = '\x1b[31m'; _CYN = '\x1b[36m'; _BLD = '\x1b[1m'

# Mirror stdout/stderr into debug.log (truncated each startup).
_teeDebugLog = ->
  stream = createWriteStream resolve(_G.ROOT, 'debug.log'), { flags: 'w' }
  _G._logStream = stream
  for name in ['stdout', 'stderr']
    s = process[name]
    orig = s.write.bind s
    s.write = (chunk, enc, cb) ->
      try stream.write chunk
      orig chunk, enc, cb

# Refuse to start if another instance is alive; clear stale PID files.
_pidGuard = ->
  pidFile = resolve _G.ROOT, 'agent.pid'
  try
    existing = parseInt (await readFile pidFile, 'utf8').trim(), 10
    try
      process.kill existing, 0
      console.error "#{_RED}Error: agent already running (pid #{existing}).#{_RST}"
      console.error "#{_DIM}If the process is gone, delete agent.pid and retry.#{_RST}"
      process.exit 1
    catch
      await unlink(pidFile).catch ->
  catch
  await writeFile pidFile, String(process.pid)
  pidFile

_importSystem = (name) ->
  filePath = resolve _G.SYSTEMS_DIR, "#{name}.coffee"
  mod = await import(filePath)
  mod.default ? mod["#{name}System"] ? mod[name]

# Hot reload: re-import edited systems/microagents without a restart.
# NOTE: a `?t=` cache-buster query reliably forces re-evaluation but, in some
# Bun + bun-coffeescript versions, breaks the .coffee loader (the import then
# resolves to a path string instead of the module). So we try the cache-busted
# import first and only accept it when it yields a real function; otherwise we
# fall back to a plain re-import and leave the running fn in place.
_reimport = (p, name) ->
  try
    mod = await import("#{p}?t=#{Date.now()}")
    fn = mod.default ? mod["#{name}System"] ? mod[name]
    return fn if typeof fn is 'function'
  catch
  try
    mod = await import(p)
    fn = mod.default ? mod["#{name}System"] ? mod[name]
    return fn if typeof fn is 'function'
  catch
  null

_watchCode = (systems) ->
  _G._codeWatcher = chokidar.watch [_G.SYSTEMS_DIR, _G.MICROAGENTS_DIR],
    ignoreInitial: true
    awaitWriteFinish: { stabilityThreshold: 200, pollInterval: 50 }
  .on 'change', (p) ->
    return unless p.endsWith '.coffee'
    name = basename p, '.coffee'
    rel = p.replace _G.ROOT + '/', ''
    sys = systems.find (s) -> s.name is name
    fn = await _reimport p, name
    if sys? and fn?
      sys.fn = fn
      console.log "#{_DIM}#{_ts()}#{_RST} ♻️  #{_GRN}reloaded system#{_RST} #{rel}"
    else if fn? or not sys?
      # Microagent (or non-system module): re-import re-registered its _G side-effect.
      console.log "#{_DIM}#{_ts()}#{_RST} ♻️  #{_GRN}reloaded#{_RST} #{rel}"
    else
      console.log "#{_DIM}#{_ts()}#{_RST} ♻️  #{_RED}reload skipped#{_RST} #{rel} #{_DIM}(restart to apply)#{_RST}"

# Convert a glob (only `*` wildcard) to a RegExp — the multi-activity --activity filter.
_globToRegExp = (pattern) ->
  escaped = pattern.replace /[-/\\^$+?.()|[\]{}]/g, '\\$&'
  new RegExp '^' + escaped.replace(/\*/g, '.*') + '$'

_argValue = (argv, flag) ->
  i = argv.indexOf flag
  if i >= 0 then argv[i + 1] else null

# Load + resolve the single-activity config.yaml systems list (fn attached).
_resolveSystems = ->
  { cfg, systems } = await loadConfig()
  for s in systems
    s.fn = await _importSystem s.name
  { cfg, systems }

# Run one activity's ordered stages once, inside its activity context (so logs +
# telemetry attribute correctly even under parallel execution). Field-index GC
# (`evictHydrated`) runs at every stage boundary so a stage's full bodies live
# only for that stage. A throwing system is logged and skipped (one bad entity
# never wedges the loop).
_runActivityStages = (activity) ->
  _G.withActivity activity.id, ->
    _G.log 'loop.start', { activity: activity.id }
    try
      for step in activity.pipeline
        break if _G.quit
        _G.currentSystem = step.name
        stop = Telemetry.startTimer "stage.#{step.name}"
        await step.fn()
        _G.Entity.evictHydrated activity.id
        stop()
    catch err
      _G.log 'loop.error', { activity: activity.id, error: err?.message ? String(err) }
    _G.log 'loop.done', { activity: activity.id }

# ── Multi-activity loop (activity-first / activities/*.yaml projects) ──────────
# Each tick runs every selected activity's declared pipeline. Activities run in
# parallel by default (_G.parallelActivities) for independent throughput, or
# sequentially for predictable logs. Opts into the field-index so a large corpus
# stays memory-bounded (a no-op for activities that declare no GATE_FIELDS).
_runMultiLoop = (allActivities, argv) ->
  pattern = _argValue argv, '--activity'
  matcher = if pattern then _globToRegExp pattern else null
  activities = if matcher then allActivities.filter((a) -> matcher.test a.id) else allActivities
  if pattern and activities.length is 0
    console.error "#{_RED}--activity '#{pattern}' matched none of: #{allActivities.map((a) -> a.id).join ', '}#{_RST}"
    process.exit 2

  # Opt into the field-index so a large corpus stays memory-bounded (a no-op for
  # activities that declare no GATE_FIELDS — they keep full-body selection).
  _G.useFieldIndex = true
  for activity in activities
    await _G.Entity.init activity.id

  console.log """

  #{_BLD}#{_CYN}  🔁 agent pipeline#{_RST}#{_DIM}  #{activities.length} #{if activities.length is 1 then 'activity' else 'activities'}#{_RST}

  #{_DIM}activities#{_RST} #{activities.map((a) -> a.id).join ' · '}
  #{_DIM}model     #{_RST} #{_G.MODEL}
  #{_DIM}mode      #{_RST} #{if _G.parallelActivities then 'parallel' else 'sequential'} #{_DIM}· field-index #{if _G.useFieldIndex then 'on' else 'off'}#{_RST}

  #{_DIM}Ctrl+C to stop gracefully.#{_RST}
  """

  while not _G.quit
    try
      if _G.parallelActivities
        await Promise.all(activities.map (a) -> _runActivityStages a)
      else
        for activity in activities
          break if _G.quit
          await _runActivityStages activity
      Telemetry.report()
      Telemetry.reset()
    catch err
      console.error "#{_RED}loop error:#{_RST}", err?.stack or err
    break if _G.quit
    await _G.sleep _G.loopIntervalMs

# ── Single-activity loop (config.yaml `systems:` projects — the scaffold) ──────
_runSingleLoop = (opts) ->
  { cfg, systems } = await _resolveSystems()
  _watchCode systems unless opts.hotReload is false
  await _G.Entity.init 'default'

  console.log """

  #{_BLD}#{_CYN}  🔁 #{cfg.name or basename _G.ROOT}#{_RST}#{_DIM}  agent pipeline#{_RST}

  #{_DIM}db     #{_RST} #{_G.DB_DIR}
  #{_DIM}model  #{_RST} #{_G.MODEL}
  #{_DIM}systems#{_RST} #{systems.map((s) -> s.name).join ' → '}

  #{_DIM}♻️  hot reload active — edits to systems/ and microagents/ apply without restart.#{_RST}
  #{_DIM}Ctrl+C to stop gracefully.#{_RST}
  """

  while not _G.quit
    try
      timings = {}
      for { name, fn } in systems
        break if _G.quit
        unless fn?
          console.error "#{_RED}system '#{name}' has no exported fn — skipping#{_RST}"
          continue
        _G.currentSystem = name
        t0 = Date.now()
        await fn()
        timings[name] = Date.now() - t0

      all = _G.World.for('default').all()
      byStage = {}
      for e in all
        st = e.workflow?._stage or 'uncaptured'
        byStage[st] = (byStage[st] or 0) + 1
      waiting = all.filter (e) -> e.workflow?._status is 'waiting_on_human'

      active = Object.entries(timings).filter ([, ms]) -> ms > 5
      timingStr = if active.length then '  ' + active.map(([n, ms]) -> "#{n}:#{ms}ms").join('  ') else ''
      stageStr = Object.entries(byStage).filter(([, n]) -> n > 0).map(([s, n]) -> "#{s}:#{n}").join '  '

      parts = ["#{_DIM}#{_ts()}#{_RST} 💤"]
      parts.push if stageStr then stageStr else "#{_DIM}no entities. loop in #{_G.loopIntervalMs / 1000}s.#{_RST}"
      parts.push "#{_DIM}(#{waiting.length} waiting)#{_RST}" if waiting.length
      parts.push "#{_DIM}#{timingStr}#{_RST}" if timingStr
      console.log parts.join ' '
    catch err
      console.error "#{_RED}loop error:#{_RST}", err?.stack or err

    break if _G.quit
    await _G.sleep _G.loopIntervalMs

# The one entry point a project's agent.coffee calls. DUAL-MODE:
#   • MULTI-ACTIVITY — the Activities registry has activities with a non-empty
#     pipeline (activity-first <id>/activity.yaml or legacy activities/*.yaml).
#     Runs every selected activity's pipeline each tick (field-index on).
#   • SINGLE-ACTIVITY — no such activities; systems come from config.yaml. The
#     scaffold's shape (today's behavior, unchanged).
# Either way, the walk/F4 flags short-circuit to runWalk first. The loop owns the
# debug-log tee, PID guard, and graceful shutdown for both modes.
export runPipeline = (opts = {}) ->
  argv = opts.argv ? process.argv.slice(2)
  await Activities.loadAll()
  _G.Activities = Activities
  multiActivities = Activities.all().filter (a) -> (a.pipeline?.length ? 0) > 0
  isMulti = multiActivities.length > 0

  # ── Walk / F4 dev harness (both modes) ──────────────────────────────────────
  # A selection of entities × a selection of stages → the shared runWalk engine.
  # Routed first, BEFORE any loop setup (no tee, no PID guard, no bulk init), so
  # you can walk entities WHILE the long-running loop runs — it streams one at a
  # time. runWalk is activity-aware; single-activity needs its config systems.
  if ['--entity', '--entities', '--stage', '--stages', '--once'].some((f) -> argv.includes f)
    walkSystems = if isMulti then null else (await _resolveSystems()).systems
    res = await runWalk { argv, systems: walkSystems }
    await _G.Entity.stopWatching?()
    process.exit(if res?.errors then 1 else 0)

  # Wire agl-ai defaults (both modes).
  Agent.default.model = _G.MODEL if Agent?.default?
  Agent.default.concurrency = _G.concurrency if Agent?.default?

  _teeDebugLog()
  pidFile = await _pidGuard()
  _removePid = -> unlink(pidFile).catch ->

  # Graceful shutdown (both modes): first Ctrl+C finishes the tick, second forces.
  sigintCount = 0
  process.on 'SIGINT', ->
    sigintCount++
    if sigintCount >= 2
      console.log "\n#{_DIM}#{_ts()}#{_RST} Force quitting."
      await _removePid()
      process.exit 1
    _G.quit = true
    console.log "\n#{_DIM}#{_ts()}#{_RST} Graceful shutdown — finishing current iteration..."
  process.on 'SIGTERM', -> _G.quit = true

  if isMulti
    await _runMultiLoop multiActivities, argv
  else
    await _runSingleLoop opts

  await _removePid()
  await _G.Entity.stopWatching?()
  _G._codeWatcher?.close?()
  console.log "#{_DIM}#{_ts()}#{_RST} stopped."

export default runPipeline
