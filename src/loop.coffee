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
import { loadConfig, loadConfigKnobs } from './config.coffee'
import { runWalk } from './walk.coffee'
import { Telemetry } from './telemetry.coffee'
import { RunMeter } from './console.coffee'

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
#
# ── WORKER-POOL MODEL (STAGE_CONCURRENCY_PLAN) ────────────────────────────────
# Stages no longer run serially-to-completion within a tick (which let a slow
# stage head-of-line-block the whole loop). Instead EVERY stage runs as its own
# continuous worker, all concurrent: each worker polls its gate, claims up to
# (width − inflight) eligible entities (excluding ones it's already processing),
# runs each via `processOne` fire-and-forget, and refills a slot the instant an
# entity finishes. `pipelineWidth` is the MAX concurrency PER STAGE. A slow stage
# saturates only its own `width` slots; the others keep flowing.

# Optional global in-flight semaphore (maxTotalInflight). Caps the SUM across all
# stages when set; a no-op (always grants) when null.
_GLOBAL_INFLIGHT = { n: 0 }
_acquireGlobalSlot = ->
  cap = _G.maxTotalInflight
  return true unless cap?
  return false if _GLOBAL_INFLIGHT.n >= cap
  _GLOBAL_INFLIGHT.n += 1
  true
_releaseGlobalSlot = -> _GLOBAL_INFLIGHT.n -= 1 if _G.maxTotalInflight?

# Update the live per-stage in-flight gauge the RunMeter renders.
_stageInflight = (name, n) ->
  return unless _G.runStats?
  (_G.runStats.stageInflight ?= {})[name] = n
  (_G.runStats.stageCounts   ?= {})[name] = n

# Run ONE entity through a stage under an optional per-stage timeout. On timeout,
# call the system's `onTimeout` hook (which marks the entity blocked so its gate
# won't re-claim it) and resolve — freeing the slot so the stage keeps moving.
_processWithTimeout = (activity, step, id) ->
  timeoutMs = _G.stageTimeoutMs?[step.name]
  run = step.processOne activity.id, id
  return (await run) unless timeoutMs? and timeoutMs > 0
  timer = null
  timed = new Promise (res) ->
    timer = setTimeout (-> res { __timeout: true }), timeoutMs
    timer?.unref?()
  outcome = await Promise.race [ run.then((v) -> { __value: v }), timed ]
  clearTimeout timer if timer
  if outcome?.__timeout
    _G.log 'stage.timeout', { stage: step.name, id, ms: timeoutMs }
    try await step.onTimeout?(activity.id, id)
    catch err then _G.log 'stage.timeout_hook_error', { stage: step.name, id, error: err?.message ? String(err) }
    # The abandoned `run` keeps executing until it finishes on its own; onTimeout
    # has already marked the entity un-claimable, so it won't be double-processed.
    return undefined
  outcome.__value

# One continuous worker for one stage. Resolves only when `_G.quit` AND its
# in-flight set has fully drained (the graceful unbounded drain — second Ctrl-C
# force-quits the process; see runPipeline's SIGINT handler).
_runStageWorker = (activity, step) ->
  inflight = new Set()
  _stageInflight step.name, 0
  hasWorker = (typeof step.selectEligible is 'function') and (typeof step.processOne is 'function')
  loop
    if _G.quit
      break if inflight.size is 0
      await _G.sleep 50
      continue

    unless hasWorker
      # Legacy adapter: a system exporting only `fn` runs its own
      # Entity.query+pMap batch. Loop it with idle backoff. It still runs
      # CONCURRENTLY with the other stages' workers (the head-of-line fix) — it
      # just lacks per-entity slot refill inside the stage.
      try await step.fn()
      catch err then _G.log 'stage.error', { stage: step.name, error: err?.message ? String(err) }
      await _G.sleep _G.loopIntervalMs
      continue

    slots = _G.pipelineWidth - inflight.size
    if slots <= 0
      await _G.sleep _G.idlePollMs
      continue
    ids = []
    try ids = (await step.selectEligible activity.id, { exclude: inflight, limit: slots, order: 'mtime' }) ? []
    catch err then _G.log 'stage.select_error', { stage: step.name, error: err?.message ? String(err) }
    if ids.length is 0
      await _G.sleep _G.loopIntervalMs
      continue
    for id in ids
      break unless _acquireGlobalSlot()
      sid = String id
      inflight.add sid
      _stageInflight step.name, inflight.size
      do (sid) ->
        Promise.resolve()
          .then -> _processWithTimeout activity, step, sid
          .catch (err) -> _G.log 'stage.error', { stage: step.name, id: sid, error: err?.message ? String(err) }
          .finally ->
            inflight.delete sid
            _releaseGlobalSlot()
            _stageInflight step.name, inflight.size
            try _G.Entity.evictHydratedOne? activity.id, sid
  undefined

# Run ALL of one activity's stages as concurrent workers. Resolves when every
# worker has drained after `_G.quit`. Cleanup hooks (e.g. close a browser pool)
# run once afterward.
_runActivity = (activity) ->
  _G.withActivity activity.id, ->
    _G.log 'loop.start', { activity: activity.id }
    try
      await Promise.all(activity.pipeline.map (step) -> _runStageWorker activity, step)
    catch err
      _G.log 'loop.error', { activity: activity.id, error: err?.message ? String(err) }
    for step in activity.pipeline when typeof step.cleanup is 'function'
      try await step.cleanup()
      catch err then _G.log 'loop.cleanup_error', { activity: activity.id, stage: step.name, error: err?.message ? String(err) }
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
  #{_DIM}width     #{_RST} #{_G.pipelineWidth} #{_DIM}per stage · stages run concurrently as worker pools#{_RST}#{if _G.maxTotalInflight? then " #{_DIM}· global cap #{_G.maxTotalInflight}#{_RST}" else ''}

  #{_DIM}Ctrl+C to stop gracefully (drains in-flight); Ctrl+C again to force quit.#{_RST}
  """

  # Live status line — spinner + elapsed + per-stage IN-FLIGHT histogram (each
  # worker updates `stageInflight`). Shared `_G.runStats` is mutated by the
  # workers + _G.log.
  stageNames = []
  for a in activities
    stageNames.push step.name for step in (a.pipeline ? []) when step.name not in stageNames
  _G.runStats =
    startedAt: Date.now()
    tick: 0
    activity: (if activities.length is 1 then activities[0].id else null)
    stage: null
    total: 0
    remaining: null
    stageCounts: {}
    stageInflight: {}
    stageMs: {}
  meter = new RunMeter _G.runStats, stageNames
  _G._runMeter = meter
  meter.start()

  # Background heartbeat: refresh the on-disk total + spin the meter's tick. The
  # actual work runs in the per-stage workers (no per-tick sweep anymore).
  hb = setInterval (->
    _G.runStats.tick += 1
    _G.runStats.total = (try (activities.reduce ((n, a) -> n + (_G.Entity.count?(a.id) ? 0)), 0) catch then _G.runStats.total)
  ), 1000
  hb?.unref?()

  # Launch every activity's worker pool concurrently and await graceful drain
  # (each _runActivity resolves only once _G.quit AND its workers have drained).
  try
    await Promise.all(activities.map (a) -> _runActivity a)
  catch err
    meter.clear()
    console.error "#{_RED}loop error:#{_RST}", err?.stack or err
  finally
    clearInterval hb
    Telemetry.report()

  meter.stop()
  _G._runMeter = null

# ── Single-activity projects → synthesized as a ONE-activity set ──────────────
# There is no separate single-activity loop anymore (STAGE_CONCURRENCY_PLAN §5.9:
# multi-activity is the only execution model). A `config.yaml systems:` scaffold
# is synthesized into one `'default'` activity whose `pipeline` is its systems
# list (each captured with its worker-pool seams + GATE_FIELDS), then run through
# the same `_runMultiLoop` worker supervisor. NOTE: hot-reload of systems is not
# carried over to this synthesized path (it was a property of the deleted serial
# loop); restart to apply edits.
_synthesizeSingleActivity = ->
  { systems } = await _resolveSystems()
  indexFields = new Set()
  anyIdx = false
  pipeline = []
  for s in systems
    filePath = resolve _G.SYSTEMS_DIR, "#{s.name}.coffee"
    mod = try (await import(filePath)) catch then {}
    fn = mod.default ? mod["#{s.name}System"] ? mod[s.name] ? s.fn
    pipeline.push {
      name: "#{s.name}System"
      fn
      selectEligible: mod.selectEligible ? null
      processOne:     mod.processOne ? null
      onTimeout:      mod.onTimeout ? null
      cleanup:        mod.cleanup ? null
    }
    if Array.isArray mod.GATE_FIELDS
      anyIdx = true
      indexFields.add f for f in mod.GATE_FIELDS
  act = Activities.get 'default'
  act.pipeline = pipeline
  act._indexFields = (if anyIdx then indexFields else null)
  [act]

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

  # Apply framework loop knobs from a root config.yaml if present (model /
  # pipeline_width / loop_interval_ms / concurrency / retry / parallel_activities /
  # max_total_inflight / stage_timeout_ms). Tolerant: defaults apply when absent.
  # Loaded for BOTH modes (single-activity is synthesized into a one-activity set).
  await loadConfigKnobs()

  # CLI override for pipeline width — `--width N` / `--pipeline-width N` wins over
  # config.yaml so you can fan out (e.g. ingest + process N new entities per tick)
  # without editing config. Applied for both loop modes; the single-activity path
  # re-reads config later, so we stash the override and re-apply below too.
  widthArg = _argValue(argv, '--width') ? _argValue(argv, '--pipeline-width')
  if widthArg?
    w = parseInt widthArg, 10
    if Number.isFinite(w) and w > 0
      _G.pipelineWidth = w
      _G._widthOverride = w
      console.log "#{_DIM}#{_ts()}#{_RST} #{_CYN}pipeline_width#{_RST} = #{w} #{_DIM}(CLI override)#{_RST}"
    else
      console.error "#{_RED}--width must be a positive integer (got '#{widthArg}')#{_RST}"
      process.exit 2

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

  # Graceful shutdown: first Ctrl+C stops claiming new entities and drains the
  # in-flight ones to completion (unbounded); a second Ctrl+C force-quits.
  sigintCount = 0
  process.on 'SIGINT', ->
    sigintCount++
    if sigintCount >= 2
      console.log "\n#{_DIM}#{_ts()}#{_RST} Force quitting."
      await _removePid()
      process.exit 1
    _G.quit = true
    console.log "\n#{_DIM}#{_ts()}#{_RST} Graceful shutdown — draining in-flight entities (Ctrl+C again to force)..."
  process.on 'SIGTERM', -> _G.quit = true

  activities = if isMulti then multiActivities else (await _synthesizeSingleActivity())
  await _runMultiLoop activities, argv

  await _removePid()
  await _G.Entity.stopWatching?()
  _G._codeWatcher?.close?()
  console.log "#{_DIM}#{_ts()}#{_RST} stopped."

export default runPipeline
