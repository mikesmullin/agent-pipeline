# pipeline/src/config.coffee
#
# Loads config.yaml (falling back to config.yaml.example) from the project root
# and applies it to _G. The `systems:` list defines execution order; each entry
# may carry an optional integer `weight:` (lower runs first). Returns the
# ordered, resolved system descriptor list.
import { readFile } from 'fs/promises'
import { resolve } from 'path'
import { load as yamlLoad } from 'js-yaml'
import { _G } from './globals.coffee'

# Read root config.yaml (or config.yaml.example) if present, returning the parsed
# object or null. Never errors / exits — knobs are optional.
_readRootConfig = ->
  for name in ['config.yaml', 'config.yaml.example']
    try
      text = await readFile resolve(_G.ROOT, name), 'utf8'
      return (yamlLoad(text or '') ? {})
    catch
  null

# Apply the framework LOOP KNOBS from a root config.yaml to _G, if the file
# exists. Tolerant — a project with NO root config (e.g. an activity-first
# multi-activity project that keeps only per-activity config) just uses the _G
# defaults. Does NOT require a `systems:` list (that is single-activity only).
# Returns the parsed cfg (or {}). Both loop modes call this so `model`,
# `pipeline_width`, `loop_interval_ms`, `concurrency`, `retry`, and
# `parallel_activities` are honored uniformly.
export loadConfigKnobs = ->
  cfg = (await _readRootConfig()) ? {}
  _G.configure
    MODEL:          cfg.model
    pipelineWidth:  cfg.pipeline_width
    loopIntervalMs: cfg.loop_interval_ms
    concurrency:    cfg.concurrency
    retry: if cfg.retry then { maxCount: cfg.retry.max_count, backoffMs: cfg.retry.backoff_ms } else undefined
  _G.parallelActivities = cfg.parallel_activities if cfg.parallel_activities?
  _G.maxTotalInflight   = cfg.max_total_inflight if cfg.max_total_inflight?
  _G.stageTimeoutMs     = cfg.stage_timeout_ms   if cfg.stage_timeout_ms?
  cfg

export loadConfig = ->
  text = null
  for name in ['config.yaml', 'config.yaml.example']
    try
      text = await readFile resolve(_G.ROOT, name), 'utf8'
      break
    catch
  unless text?
    console.error 'ERROR: neither config.yaml nor config.yaml.example found in project root.'
    process.exit 1

  cfg = yamlLoad(text or '') ? {}

  _G.configure
    MODEL:          cfg.model
    pipelineWidth:  cfg.pipeline_width
    loopIntervalMs: cfg.loop_interval_ms
    concurrency:    cfg.concurrency
    retry: if cfg.retry then { maxCount: cfg.retry.max_count, backoffMs: cfg.retry.backoff_ms } else undefined

  unless cfg.systems?.length
    console.error 'ERROR: config file must define a non-empty systems: list.'
    process.exit 1

  systems = cfg.systems
    .map (s, i) ->
      entry = if typeof s is 'string' then { name: s } else s
      { name: entry.name, weight: entry.weight ? (i + 1) * 10 }
    .sort (a, b) -> a.weight - b.weight

  { cfg, systems }

export default loadConfig
