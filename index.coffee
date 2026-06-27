# pipeline — ECS-inspired, disk-authoritative agent-pipeline framework.
#
# Single import surface for projects that depend on the framework:
#
#   import { _G, Entity, Activities, World, SchemaValidator, Component,
#            defineComponent, runPipeline, Agent } from 'pipeline'
#
# Two tiers (see docs/ARCHITECTURE.md):
#   • `pipeline/data` — the DATA / ORM surface (per-id IO + Activities + ACL).
#     A thin client (UI) imports ONLY this; it knows nothing about stages.
#   • `pipeline` (here) — DATA tier PLUS the ECS / orchestration tier
#     (Gate / gateTrace / loadConfig / runPipeline). The agent imports this.
import Agent from 'agl-ai'
import { _G, Entity, Activities, World, SchemaValidator, Component, defineComponent, normalizeStrings } from './src/data.coffee'
import { Gate, gateTrace } from './src/gate.coffee'
import { loadConfig } from './src/config.coffee'
import { runPipeline } from './src/loop.coffee'
import { runWalk } from './src/walk.coffee'

export { _G, Agent, Entity, Activities, World, SchemaValidator, Component, defineComponent, normalizeStrings, Gate, gateTrace, loadConfig, runPipeline, runWalk }
export default _G
