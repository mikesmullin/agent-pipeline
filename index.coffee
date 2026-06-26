# pipeline — ECS-inspired, disk-authoritative agent-pipeline framework.
#
# Single import surface for projects that depend on the framework:
#
#   import { _G, Entity, World, SchemaValidator, Component, defineComponent,
#            runPipeline, Agent } from 'pipeline'
#
# See docs/ARCHITECTURE.md for the contract these primitives enforce.
import Agent from 'agl-ai'
import { _G } from './src/globals.coffee'
import './src/world.coffee'
import { Entity } from './src/entity.coffee'
import { Activities } from './src/activities.coffee'
import { SchemaValidator } from './src/schema-validator.coffee'
import { Component, defineComponent } from './src/component.coffee'
import { Gate, gateTrace } from './src/gate.coffee'
import { normalizeStrings } from './src/normalize.coffee'
import { loadConfig } from './src/config.coffee'
import { runPipeline } from './src/loop.coffee'

World = _G.World

export { _G, Agent, Entity, Activities, World, SchemaValidator, Component, defineComponent, Gate, gateTrace, normalizeStrings, loadConfig, runPipeline }
export default _G
