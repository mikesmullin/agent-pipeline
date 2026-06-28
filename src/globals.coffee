# pipeline/src/globals.coffee
#
# The process-wide shared state singleton `_G`. Unlike a per-project globals
# file, this framework version computes paths from the CONSUMING project's
# working directory (process.cwd()), so the same code works whether it is run
# from the project root or imported as a linked dependency.
#
# A project may override any of these via `_G.configure({...})` (the loop does
# this from config.yaml) or the PIPELINE_ROOT env var.
import { resolve } from 'path'
import { readFile } from 'fs/promises'
import { createHash } from 'crypto'
import { AsyncLocalStorage } from 'async_hooks'
import { formatLogLine as _fmtLog } from './console.coffee'

_ROOT = resolve(process.env.PIPELINE_ROOT or process.cwd())

# 16 pleasant low-saturation rainbow colors (24-bit ANSI fg) for per-entity log tint.
_PALETTE = [
  '\x1b[38;2;235;100;100m', '\x1b[38;2;235;140;80m',  '\x1b[38;2;225;185;60m'
  '\x1b[38;2;190;210;60m',  '\x1b[38;2;120;210;90m',  '\x1b[38;2;75;200;140m'
  '\x1b[38;2;65;200;195m',  '\x1b[38;2;80;185;235m',  '\x1b[38;2;90;155;240m'
  '\x1b[38;2;130;115;240m', '\x1b[38;2;175;95;235m',  '\x1b[38;2;215;85;215m'
  '\x1b[38;2;235;85;170m',  '\x1b[38;2;160;210;170m', '\x1b[38;2;170;200;235m'
  '\x1b[38;2;235;175;135m'
]
_RESET = '\x1b[0m'
_DIM   = '\x1b[2m'

_idColor = (id) ->
  hash = createHash('sha1').update(String id).digest('hex')
  _PALETTE[parseInt(hash.slice(0, 4), 16) % _PALETTE.length]

# Per-async-chain activity context. Survives await boundaries within ONE Promise
# chain but does NOT bleed into sibling chains, so a multi-activity loop can run
# its activities in parallel and still attribute logs/telemetry to the right one.
_activityContext = new AsyncLocalStorage()

export _G =
  ROOT:           _ROOT
  DB_DIR:         resolve _ROOT, 'db'
  SCHEMA_DIR:     resolve _ROOT, 'schema'
  SYSTEMS_DIR:    resolve _ROOT, 'systems'
  MICROAGENTS_DIR: resolve _ROOT, 'microagents'

  MODEL:          process.env.AGENT_MODEL or 'copilot:claude-sonnet-4.6'
  DIM:            _DIM
  RESET:          _RESET

  # Loop knobs (overridable by config.yaml)
  pipelineWidth:  3
  loopIntervalMs: 5000
  concurrency:    6
  retry:
    maxCount:  5
    backoffMs: 60_000

  # ── Worker-pool knobs (STAGE_CONCURRENCY_PLAN) ──────────────────────────────
  # Each stage runs as its own continuous worker, processing up to `pipelineWidth`
  # entities concurrently and independently of the other stages (a slow stage no
  # longer head-of-line-blocks the whole loop).
  #
  # maxTotalInflight: optional global cap on the SUM of in-flight entities across
  #   all stages (null = OFF → pure per-stage; the worst case is width × stages).
  maxTotalInflight: null
  # stageTimeoutMs: per-stage hard timeout for ONE entity's processing, keyed by
  #   the stage's system name (e.g. { verifySystem: 300000 }). When an entity
  #   exceeds it, the worker aborts it, the system's onTimeout hook marks it
  #   blocked, and the slot frees for the next entity. {} = no timeouts (stages
  #   whose every op is fast — resolve/publish/report — need none).
  stageTimeoutMs: {}
  # idlePollMs: how often a fully-saturated worker re-checks for a freed slot.
  idlePollMs: 25

  quit: false
  currentEntityId: null
  currentSystem: null

  # Live run telemetry for the loop status line (RunMeter reads this; the loop
  # and _G.log mutate it). null until the multi-activity loop starts.
  runStats: null
  _runMeter: null
  # Activity registry pointer (set by the loop / server at startup) so _G.log can
  # read an activity's accentColor without a circular import.
  Activities: null
  # F4 dev harness: when set, Entity.query restricts selection to this single id
  # (so `agent.coffee --entity <id> --stage <name>` runs one stage on one entity).
  onlyEntity: null

  # Multi-activity loop: run each tick's activities in parallel (true) or
  # sequentially (false). Sequential gives predictable logs + no cross-activity
  # contention; parallel halves wall-time per tick when activities are independent.
  parallelActivities: true

  sleep: (ms) -> new Promise (res) -> setTimeout res, ms

  # Activity context (AsyncLocalStorage). `withActivity` runs fn inside the named
  # activity's context; `currentActivity` reads it back (null outside any). The
  # multi-activity loop wraps each activity's stages in `withActivity`, so an
  # overridden `_G.log` / Telemetry can tag output with the active activity even
  # when activities run in parallel.
  withActivity: (activityId, fn) -> _activityContext.run { activityId }, fn
  currentActivity: -> _activityContext.getStore()?.activityId ? null

  # Reconfigure paths/knobs at startup. Recomputes derived dirs when ROOT changes.
  configure: (opts = {}) ->
    if opts.root
      _G.ROOT           = resolve opts.root
      _G.DB_DIR         = resolve _G.ROOT, 'db'
      _G.SCHEMA_DIR     = resolve _G.ROOT, 'schema'
      _G.SYSTEMS_DIR    = resolve _G.ROOT, 'systems'
      _G.MICROAGENTS_DIR = resolve _G.ROOT, 'microagents'
    for key in ['DB_DIR', 'SCHEMA_DIR', 'SYSTEMS_DIR', 'MICROAGENTS_DIR', 'MODEL', 'pipelineWidth', 'loopIntervalMs', 'concurrency']
      _G[key] = opts[key] if opts[key]?
    if opts.retry
      _G.retry.maxCount  = opts.retry.maxCount  ? _G.retry.maxCount
      _G.retry.backoffMs = opts.retry.backoffMs ? _G.retry.backoffMs
    _G

  # Replace {{file:/abs/path}} placeholders in a prompt template with file contents.
  loadPrompt: (template) ->
    result = template
    for match in [...template.matchAll /\{\{file:([^}]+)\}\}/g]
      filePath = match[1].trim()
      try
        content = await readFile filePath, 'utf8'
      catch
        content = "(unavailable: #{filePath})"
      result = result.split(match[0]).join content
    result

  log: (label, data = {}) ->
    ts = new Date().toISOString()
    # Activity chip — color from the activity's accentColor (activity.yaml), else
    # a stable hashed pastel. Read lazily via the _G.Activities pointer (set by
    # the loop) to avoid a circular import with activities.coffee.
    tag = null
    activityId = _G.currentActivity?()
    if activityId
      color = try _G.Activities?.get?(activityId)?.accentColor catch then null
      tag = { text: String(activityId).split('-')[0], color }
    # Feed the live status line: a stage's `count`/`remaining` describe progress.
    if _G.runStats?
      st = _G.runStats.stage
      _G.runStats.stageCounts[st] = data.count if st and typeof data?.count is 'number'
      _G.runStats.remaining = data.remaining if typeof data?.remaining is 'number'
    # Clear the status line so the scrolling log doesn't collide with it; the
    # meter's next interval repaints below.
    _G._runMeter?.clear?()
    console.log _fmtLog ts, label, data, tag

  # Trace a step with an inline spinner-style ✓/✗. Returns fn()'s result.
  traceStep: (emoji, label, fn) ->
    ts = new Date().toLocaleTimeString('en-US', { hour12: false })
    idPart = if _G.currentEntityId
      " #{_idColor _G.currentEntityId}[#{_G.currentEntityId}]#{_RESET}"
    else ''
    process.stdout.write "#{_DIM}[#{ts}]#{_RESET}#{idPart} #{emoji} #{label}..."
    try
      result = await fn()
      process.stdout.write ' ✓\n'
      result
    catch err
      process.stdout.write ' ✗\n'
      throw err

export default _G
