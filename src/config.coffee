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
