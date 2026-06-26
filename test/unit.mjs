// pipeline/test/unit.mjs — pure-logic tests (no LLM, no network).
// Run: bun test/unit.mjs

import 'bun-coffeescript/register'
import { mkdtempSync, rmSync, writeFileSync, mkdirSync } from 'fs'
import { tmpdir } from 'os'
import { resolve } from 'path'

let pass = 0, fail = 0
const ok = (cond, msg) => { if (cond) { pass++; console.log(`  ✓ ${msg}`) } else { fail++; console.log(`  ✗ ${msg}`) } }
const eq = (a, b, msg) => ok(JSON.stringify(a) === JSON.stringify(b), `${msg} (got ${JSON.stringify(a)})`)

// Isolated project root.
const root = mkdtempSync(resolve(tmpdir(), 'pipeline-test-'))
mkdirSync(resolve(root, 'schema'), { recursive: true })
writeFileSync(resolve(root, 'schema', 'thing.yaml'), `entity: thing
scalars:
  id:
    type: string
    subjects: [system:thing/echo]
components:
  workflow:
    fields:
      stage:
        type: string
        subjects: [system:thing/echo]
  note:
    fields:
      text:
        type: string
        subjects: [system:thing/echo]
      seen_at:
        type: string
        subjects: [system:thing/echo]
`)
process.env.PIPELINE_ROOT = root

const { _G } = await import('../src/globals.coffee')
_G.configure({ root })
await import('../src/world.coffee')
const { Entity } = await import('../src/entity.coffee')
const { SchemaValidator } = await import('../src/schema-validator.coffee')
const { defineComponent } = await import('../src/component.coffee')

console.log('globals')
eq(_G.ROOT, root, 'ROOT points at project root')
eq(_G.DB_DIR, resolve(root, 'db'), 'DB_DIR derived from ROOT')

console.log('Entity + World')
await Entity.init()
const id = Entity.generateId('seed-1')
ok(/^[0-9a-f]{7}$/.test(id), '7-char hex id')
let e = await Entity.load(id)
e = await Entity.transition(e, 'captured')
eq(_G.World.get(id).workflow.stage ?? _G.World.get(id).workflow._stage, 'captured', 'transition set stage')
e = await Entity.patch(e, 'note', { text: 'hi' })
eq(_G.World.get(id).note.text, 'hi', 'patch wrote component')
e = await Entity.merge(e, 'note', { seen_at: 't0' })
eq(_G.World.get(id).note.text, 'hi', 'merge preserved sibling field')
eq(_G.World.get(id).note.seen_at, 't0', 'merge added field')

// Query primitive
const found = _G.World.Entity__find((x) => x.workflow?._stage === 'captured')
eq(found.length, 1, 'Entity__find selects by stage')

// drop() rewinds
e = await Entity.drop(e, ['note'])
eq(_G.World.get(id).note, undefined, 'drop removed component')

console.log('SchemaValidator')
SchemaValidator.check('system:thing/echo', 'note', 'text')  // should not exit
pass++; console.log('  ✓ authorized access passes')
// Unauthorized / unknown would call process.exit(1); we assert allowlist contents instead.
const schemas = SchemaValidator._loadAll()
ok(schemas.components.note.fields.text.subjects.includes('system:thing/echo'), 'allowlist loaded from disk')
ok(!schemas.components.note.fields.text.subjects.includes('system:thing/nope'), 'unauthorized subject absent')

console.log('defineComponent')
const NoteComponent = defineComponent('note', ['text', 'seen_at'])
e = await Entity.load(id)
await NoteComponent.setText('system:thing/echo', id, 'world')
eq(_G.World.get(id).note.text, 'world', 'defineComponent setter persists')
const t = await NoteComponent.text('system:thing/echo', id)
eq(t, 'world', 'defineComponent getter reads')

console.log('Gate')
const { Gate, gateTrace } = await import('../src/gate.coffee')
_G.currentSystem = 'system:thing/echo'
_G.currentEntityId = id
eq(Gate('captured', true), true, 'Gate(label,cond) returns cond (true)')
eq(Gate(false), false, 'Gate(cond) returns cond (false)')
eq(Gate('x', 5), 5, 'Gate is a pass-through for any value')
const trace = gateTrace(id)
ok(trace.length >= 2, 'gateTrace records evaluations for the entity')
ok(trace.some((g) => g.label === 'captured' && g.passed === true), 'trace captures label + pass')
ok(trace.some((g) => g.passed === false), 'trace captures a failed gate (why-stuck view)')

console.log('Entity.query')
// Three entities at different stages; query should match by predicate and cap.
const ids = ['q1', 'q2', 'q3'].map((s) => Entity.generateId(s))
for (const qid of ids) { let q = await Entity.load(qid); await Entity.transition(q, 'captured') }
let matched = await Entity.query((e) => { return e.workflow?._stage === 'captured' ? undefined : false })
ok(matched.length >= 3, 'query matches captured entities (undefined return = match)')
const onlyFalse = await Entity.query((e) => false)
eq(onlyFalse.length, 0, 'predicate returning false excludes all')
_G.pipelineWidth = 2
const capped = await Entity.query((e) => undefined)
eq(capped.length, 2, 'query caps at pipelineWidth')
const limited = await Entity.query((e) => undefined, { limit: 1 })
eq(limited.length, 1, 'query honors explicit limit')

// F4 dev harness: _G.onlyEntity scopes selection to a single entity id.
_G.onlyEntity = ids[1]
const scoped = await Entity.query((e) => undefined)
eq(scoped.length, 1, 'onlyEntity scopes query to one entity')
ok(scoped[0]?.id === ids[1], 'onlyEntity selects the requested id')
_G.onlyEntity = null
const unscoped = await Entity.query((e) => undefined, { limit: 1 })
eq(unscoped.length, 1, 'clearing onlyEntity restores normal selection')

// Cleanup
_G._watcher?.close?.()
rmSync(root, { recursive: true, force: true })

console.log(`\n${pass} passed, ${fail} failed`)
process.exit(fail > 0 ? 1 : 0)
