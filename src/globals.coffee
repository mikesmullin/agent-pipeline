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

  quit: false
  currentEntityId: null
  currentSystem: null
  # F4 dev harness: when set, Entity.query restricts selection to this single id
  # (so `agent.coffee --entity <id> --stage <name>` runs one stage on one entity).
  onlyEntity: null

  sleep: (ms) -> new Promise (res) -> setTimeout res, ms

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

  log: (tag, data) ->
    ts = new Date().toLocaleTimeString('en-US', { hour12: false })
    idPart = if _G.currentEntityId
      " #{_idColor _G.currentEntityId}[#{_G.currentEntityId}]#{_RESET}"
    else ''
    console.log "#{_DIM}[#{ts}]#{_RESET}#{idPart} #{tag}", if data then JSON.stringify(data) else ''

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
