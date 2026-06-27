# pipeline/src/data.coffee — the DATA tier (the ORM surface).
#
# This is everything a THIN CLIENT (e.g. a UI) needs to read, write, and resolve
# entities on disk — and NOTHING about stages, gates, selection, or the loop.
# A UI imports `pipeline/data`; the agent imports `pipeline` (which adds the ECS
# / orchestration tier on top of this). See docs/ARCHITECTURE.md.
#
#   DATA tier  (here)         : _G, Entity (per-id IO), Activities (manifest/labels
#                               + entity-dir resolution), World.for, SchemaValidator,
#                               Component / defineComponent, normalizeStrings.
#   ECS tier   (index.coffee) : the above PLUS Gate / gateTrace / loadConfig /
#                               runPipeline (orchestration the UI never touches).
#
# NOTE: `Entity` is a single static class that also carries ECS methods
# (query/init/evict/…). A UI simply never calls those; the meaningful boundary is
# that the genuinely-separate orchestration exports (Gate/runPipeline) live only
# in the default `pipeline` entrypoint, so a UI cannot accidentally import them.
import { _G } from './globals.coffee'
import './world.coffee'
import { Entity } from './entity.coffee'
import { Activities } from './activities.coffee'
import { SchemaValidator } from './schema-validator.coffee'
import { Component, defineComponent } from './component.coffee'
import { normalizeStrings } from './normalize.coffee'

World = _G.World

export { _G, Entity, Activities, World, SchemaValidator, Component, defineComponent, normalizeStrings }
export default _G
