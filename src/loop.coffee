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
import { loadConfig } from './config.coffee'

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

export runPipeline = (opts = {}) ->
  { cfg, systems } = await loadConfig()
  _teeDebugLog()
  pidFile = await _pidGuard()

  # Resolve each configured system to its fn.
  for s in systems
    s.fn = await _importSystem s.name

  # Wire agl-ai defaults.
  Agent.default.model = _G.MODEL if Agent?.default?
  Agent.default.concurrency = _G.concurrency if Agent?.default?

  _watchCode systems unless opts.hotReload is false

  _removePid = -> unlink(pidFile).catch ->
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

  await _G.Entity.init()

  # ── F4: single-entity / single-stage dev harness ────────────────────────────
  # `agent.coffee --entity <id> --stage <name> [--once]` runs ONE system pass
  # (optionally just one stage), scoped to ONE entity, then prints the gate trace
  # + the entity's component diff and exits — for walking a real entity through
  # the pipeline by hand. `--once` (no entity/stage) runs the whole pipeline once.
  argv = opts.argv ? process.argv.slice(2)
  _arg = (flag) ->
    i = argv.indexOf flag
    if i >= 0 then (argv[i + 1] ? true) else null
  onceEntity = _arg('--entity')
  onceStage  = _arg('--stage')
  onceFlag   = argv.includes('--once') or onceEntity? or onceStage?

  if onceFlag
    _snap = (id) ->
      e = _G.World.get id
      return null unless e
      { _mtime, _path, rest... } = e
      JSON.parse JSON.stringify rest
    _G.onlyEntity = onceEntity if onceEntity?
    runSystems = if onceStage? then systems.filter((s) -> s.name is onceStage) else systems
    if onceStage? and runSystems.length is 0
      console.error "#{_RED}no system named '#{onceStage}'. Available: #{systems.map((s) -> s.name).join ', '}#{_RST}"
      await _removePid?(); process.exit 1
    before = if onceEntity? then _snap(onceEntity) else null
    gateStart = (_G.gateLog?.length) ? 0
    console.log "#{_BLD}#{_CYN}▶ run-once#{_RST} #{_DIM}entity=#{onceEntity ? '(all)'} stage=#{onceStage ? '(all)'}#{_RST}\n"
    for { name, fn } in runSystems
      continue unless fn?
      _G.currentSystem = name
      t0 = Date.now()
      try
        await fn()
        console.log "#{_GRN}✓#{_RST} #{name} #{_DIM}#{Date.now() - t0}ms#{_RST}"
      catch err
        console.error "#{_RED}✗ #{name}#{_RST}", err?.stack or err
    if onceEntity?
      # Gate trace for this entity (the "why selected / skipped" view).
      trace = (_G.gateLog ? []).slice(gateStart).filter (g) -> String(g.entity) is String(onceEntity)
      if trace.length
        console.log "\n#{_BLD}gate trace#{_RST} #{_DIM}(#{onceEntity})#{_RST}"
        for g in trace
          mark = if g.passed then "#{_GRN}✓#{_RST}" else "#{_RED}✗#{_RST}"
          console.log "  #{mark} #{_DIM}#{g.system}#{_RST} #{g.label ? ''}"
      # Component diff.
      after = _snap(onceEntity)
      keys = [...new Set([...Object.keys(before ? {}), ...Object.keys(after ? {})])].sort()
      changed = keys.filter (k) -> JSON.stringify(before?[k]) isnt JSON.stringify(after?[k])
      console.log "\n#{_BLD}component diff#{_RST} #{_DIM}(#{onceEntity})#{_RST}"
      if changed.length is 0
        console.log "  #{_DIM}(no component changes)#{_RST}"
      else
        for k in changed
          tag = if before?[k] is undefined then "#{_GRN}+#{_RST}" else if after?[k] is undefined then "#{_RED}-#{_RST}" else "#{_CYN}~#{_RST}"
          console.log "  #{tag} #{k}"
    await _removePid()
    _G._watcher?.close?()
    _G._codeWatcher?.close?()
    process.exit 0

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

      all = _G.World.all()
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

  await _removePid()
  _G._watcher?.close?()
  _G._codeWatcher?.close?()
  console.log "#{_DIM}#{_ts()}#{_RST} stopped."

export default runPipeline
