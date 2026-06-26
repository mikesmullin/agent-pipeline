// pipeline/test/unit.mjs — pure-logic tests (no LLM, no network).
// Run: bun test/unit.mjs

import 'bun-coffeescript/register'
import { mkdtempSync, rmSync, writeFileSync, mkdirSync, readFileSync } from 'fs'
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
await Entity.init('default')
const id = Entity.generateId('seed-1')
ok(/^[0-9a-f]{7}$/.test(id), '7-char hex id')
let e = await Entity.load('default', id)
e = await Entity.transition('default', e, 'captured')
const W = _G.World.for('default')
eq(W.get(id).workflow.stage ?? W.get(id).workflow._stage, 'captured', 'transition set stage')
e = await Entity.patch('default', e, 'note', { text: 'hi' })
eq(W.get(id).note.text, 'hi', 'patch wrote component')
e = await Entity.merge('default', e, 'note', { seen_at: 't0' })
eq(W.get(id).note.text, 'hi', 'merge preserved sibling field')
eq(W.get(id).note.seen_at, 't0', 'merge added field')

// Query primitive
const found = W.Entity__find((x) => x.workflow?._stage === 'captured')
eq(found.length, 1, 'Entity__find selects by stage')

// drop() rewinds
e = await Entity.drop('default', e, ['note'])
eq(W.get(id).note, undefined, 'drop removed component')

console.log('SchemaValidator')
SchemaValidator.check('system:thing/echo', 'note', 'text')  // should not exit
pass++; console.log('  ✓ authorized access passes')
// Unauthorized / unknown would call process.exit(1); we assert allowlist contents instead.
const schemas = SchemaValidator._loadAll()
ok(schemas.components.note.fields.text.subjects.includes('system:thing/echo'), 'allowlist loaded from disk')
ok(!schemas.components.note.fields.text.subjects.includes('system:thing/nope'), 'unauthorized subject absent')

console.log('defineComponent')
const NoteComponent = defineComponent('note', ['text', 'seen_at'])
e = await Entity.load('default', id)
await NoteComponent.setText('system:thing/echo', 'default', id, 'world')
eq(W.get(id).note.text, 'world', 'defineComponent setter persists')
const t = await NoteComponent.text('system:thing/echo', 'default', id)
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
for (const qid of ids) { let q = await Entity.load('default', qid); await Entity.transition('default', q, 'captured') }
let matched = await Entity.query('default', (e) => { return e.workflow?._stage === 'captured' ? undefined : false })
ok(matched.length >= 3, 'query matches captured entities (undefined return = match)')
ok(matched.every((m) => typeof m === 'object' && m.id), 'query returns full entity objects (D2)')
const onlyFalse = await Entity.query('default', (e) => false)
eq(onlyFalse.length, 0, 'predicate returning false excludes all')
_G.pipelineWidth = 2
const capped = await Entity.query('default', (e) => undefined)
eq(capped.length, 2, 'query caps at pipelineWidth')
const limited = await Entity.query('default', (e) => undefined, { limit: 1 })
eq(limited.length, 1, 'query honors explicit limit')

// evict frees the cached body; a later load re-reads from disk.
const evictId = ids[0]
Entity.evict('default', evictId)
eq(W.get(evictId), undefined, 'evict removes the entity from World')
const rehydrated = await Entity.load('default', evictId)
eq(rehydrated.workflow?._stage, 'captured', 'load re-reads evicted entity from disk')

// F4 dev harness: _G.onlyEntity scopes selection to a single entity id.
_G.onlyEntity = ids[1]
const scoped = await Entity.query('default', (e) => undefined)
eq(scoped.length, 1, 'onlyEntity scopes query to one entity')
ok(scoped[0]?.id === ids[1], 'onlyEntity selects the requested id')
_G.onlyEntity = null
const unscoped = await Entity.query('default', (e) => undefined, { limit: 1 })
eq(unscoped.length, 1, 'clearing onlyEntity restores normal selection')

console.log('Field index (projection mode)')
// Turn on index mode and declare an index covering only note.text. The World
// should then hold projections (no note.seen_at), query should hydrate full
// bodies, writes must NOT truncate non-indexed fields, and evictHydrated should
// shrink back to projections.
const { Activities } = await import('../src/activities.coffee')
await Activities.loadAll()
Activities.get('default')._indexFields = new Set(['note.text'])  // simulate GATE_FIELDS union
_G.useFieldIndex = true
// Seed an entity with an INDEXED field (note.text) + a NON-indexed field
// (note.seen_at) + a heavy non-indexed component (revisions).
const fx = Entity.generateId('fx-1')
let fe = await Entity.load('default', fx)
fe = await Entity.patch('default', fe, 'note', { text: 'keep', seen_at: 'NON_INDEXED' })
fe = await Entity.merge('default', fe, 'revisions', {})  // ensure a component exists
// Re-read from disk into a projection (simulate init/reload in index mode).
await Entity._loadFromDisk('default', fx, W.get(fx)._path)
const proj = W.get(fx)
eq(proj.note.text, 'keep', 'projection carries the indexed field')
eq(proj.note.seen_at, undefined, 'projection DROPS the non-indexed field')
// Query hydrates the match to a FULL body (non-indexed field visible again).
const hits = await Entity.query('default', (e) => (e.note?.text === 'keep' ? undefined : false))
eq(hits.length, 1, 'index-mode query selects on the projected field')
eq(hits[0].note.seen_at, 'NON_INDEXED', 'query returns a HYDRATED full entity')
ok(hits[0]._full === true, 'hydrated entity is marked full')
// Write-safety: a setter (load outside scan = full) must not truncate the
// non-indexed field on save.
const NoteIdx = defineComponent('note', ['text', 'seen_at'])
await NoteIdx.setText('system:thing/echo', 'default', fx, 'changed')
const disk = (await import('js-yaml')).load(readFileSync(W.get(fx)._path, 'utf8'))
eq(disk.note.text, 'changed', 'setter persisted the indexed field')
eq(disk.note.seen_at, 'NON_INDEXED', 'setter did NOT truncate the non-indexed field')
// evictHydrated re-projects: full bodies shrink back to projections.
Entity.evictHydrated('default')
eq(W.get(fx).note.seen_at, undefined, 'evictHydrated re-projected the entity')
ok(W.get(fx)._full !== true, 'evicted entity is a projection, not full')
_G.useFieldIndex = false

// Cleanup
await Entity.stopWatching()
rmSync(root, { recursive: true, force: true })

console.log(`\n${pass} passed, ${fail} failed`)
process.exit(fail > 0 ? 1 : 0)
