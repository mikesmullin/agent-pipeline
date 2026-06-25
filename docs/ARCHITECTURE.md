# Agent Pipeline Architecture (the framework contract)

This is the contract every pipeline built on `pipeline` adheres to. It is an
ECS (Entity-Component-System) pattern borrowed from game engines, plus one
addition for agentic work — the **agent**, the only place an LLM exercises
judgment. (An *agent* is any AGL agent; a **microagent** is the focused subset
that answers one question via one typed tool call — see `MICROAGENT.md`.) The
conventions here are enforced two ways: structurally by the `SchemaValidator` +
`pipeline check`, and subjectively by `pipeline review` (LLM `code-review` rules).

## The five primitives

| Primitive | What it is | Where it lives |
|---|---|---|
| **Entity** | One unit of work in flight. Opaque except for `id`. | `db/<id>.yaml` — **disk is the source of truth** |
| **Component** | A named, typed bag of fields on an entity (`workflow`, `note`, …). | a top-level key in the entity YAML; declared in `schema/*.yaml` |
| **System** | A function that advances entities through one stage. | `systems/<name>.coffee` |
| **Agent** (superset) | An LLM call. The **microagent** subset answers one question via one typed tool call. | `microagents/NN-name.coffee` (subset) · `agents/NN-name.coffee` (other agents) — see `MICROAGENT.md` |
| **The loop** | The engine tick: runs systems in weight order every N ms. | `agent.coffee` → `runPipeline()` |

ECS mapping: **E**ntities are dumb data, **C**omponents are data namespaces,
**S**ystems are the behavior, the loop is the frame tick.

## The non-negotiable invariants

1. **Disk is authoritative; the World cache is only a performance layer.** State
   is fully serialized to YAML per entity. A `chokidar` watcher syncs operator
   edits back into the cache on the next tick. The process can crash and resume
   every entity exactly where it left off.

2. **Systems pull, they are never pushed.** A system's first act is to *query*
   the world for the entities it wants:
   `World.Entity__find (e) -> e.workflow?._stage is 'captured'`. Passing an
   `entity` or `store` into a system is an anti-pattern.

3. **Query by component *presence* (archetype-style).** An entity is defined by
   which components it has. A bare entity is just an id and holds no data outside
   its components. Entities **accrete** components as systems refine them.

4. **Static, Golang-style models.** `Entity` and `World` are static singletons;
   methods take the entity (or id) as the first argument — no per-entity object
   graph threaded through the loop.

5. **Microagents do judgment only.** I/O, shell, parsing, retries, validation,
   side-effects, and final string formatting stay out of the model. The calling
   system owns every `save`/`transition`. (~1:1 component:microagent — a
   microagent's output is stored on a component, then fed to the next.)

6. **Human gates are fields on disk, edited asynchronously.** A `null`/empty
   gate field = no-op this entity (keep looping); a truthy value = advance. A
   gate never blocks the loop for *other* entities.

7. **Machine vs human fields by convention.** A leading `_` means
   machine-managed; an unprefixed field is the operator's to set.

8. **Stage lives inside the entity (`workflow._stage`); files never move.**

9. **Systems run in configurable weight order**, with bounded parallelism
   (`pipeline_width`) and per-entity retry/backoff (`Entity.recordError` +
   `Entity.inBackoff`).

10. **Schema is the single source of truth + a per-field ACL.** Every component
    field declares a `subjects:` allowlist (`system:` / `agent:` /
    `route:` identities). The `SchemaValidator` enforces it at runtime (fatal on
    violation); `pipeline check` enforces it statically.

11. **Re-queue by component-deletion.** To rewind an entity, `Entity.drop(...)`
    the relevant component keys; the archetype-presence query re-picks it up at
    the earliest missing stage. This is the basis of verify → refine → reprocess
    loops.

12. **Maker ≠ Checker.** When adding verification/judge stages, the generator
    and each critic must be *distinct subjects* (and ideally distinct models) so
    nothing grades its own output.

13. **Gate logic goes through the `Gate(...)` marker.** Every entity-selection
    predicate and processing guard is wrapped in `Gate` (see below) so the gate
    logic is enforceable, debuggable, and self-documenting — the same discipline
    the ACL applies to component access.

## Gate logic (the `Gate(...)` marker)

Gate logic — *which* entities a system selects, and *when* it aborts processing
one — is the most safety-critical code in a pipeline. When it's wrong, an entity
silently gets "stuck" (never selected, or always skipped). To make it a
first-class, parsable construct, every piece of gate logic is wrapped in the
`Gate` marker, and systems select their entities through the `Entity.query` seam:

```coffeescript
import { Entity, Gate } from 'pipeline'

# Entity.query runs the gate predicate over the World and returns up to
# pipelineWidth matches. A predicate matches UNLESS it returns false, so the
# guards read naturally and "falling through" = a match:
targets = await Entity.query (e) ->
  return false unless Gate 'captured',   e.workflow?._stage is 'captured'
  return false if     Gate 'in backoff', Entity.inBackoff e
  # …falls through → this entity matches

for entity in targets
  …
```

`Entity.query` owns the `pipelineWidth` cap (a framework default, **not** system gate
logic) and sets `_G.currentEntityId` before each predicate call so `Gate()` attributes
correctly. `Gate(cond)` / `Gate(label, cond)` is a **pass-through** — it returns the boolean
it wraps, so it can be dropped around existing logic without refactoring. Because
all gate logic flows through this one marker:

- **`pipeline check`** flags gate-ish lines (the `Entity.query` predicate and any
  `continue/break/return-false if/unless` guards) in a system that are *not* wrapped in
  `Gate` (static enforcement). A deliberate exception may carry a trailing `# gate:ignore`.
- **`pipeline docs`** extracts each `Gate(...)` label + condition verbatim into a
  **Gate Logic** table — deterministically, no LLM.
- **Runtime** records each gate's pass/fail for the current entity in `_G.gateLog`;
  `gateTrace(entityId)` returns that entity's recent gate evaluations — the
  "why is X stuck?" view.

## Subject identity convention

Every accessor's first argument is the caller's identity string. An **agent** is the
superset (any AGL agent); a **microagent** is the focused subset (see `MICROAGENT.md`).
Both carry the `agent:` prefix — the label is a stable, path-independent identifier,
not derived from the file's location.

| Caller | Pattern | Example |
|---|---|---|
| System | `system:<entity>/<basename>` | `system:beam-rule/fetch` |
| Agent (incl. microagent) | `agent:<entity>/<label>` | `agent:beam-rule/convert-rule`, `agent:beam-rule/chat` |
| HTTP route | `route:<entity>/:uid/<verb>` | `route:beam-rule/:uid/approve` |

Declare a top-of-file constant `SYSTEM = '...'` (or `SUBJECT = '...'`) so both
the runtime and `pipeline check` can resolve it.

## The tooling that enforces this

- `pipeline check` — static analyzer: every `Component.method SUBJECT, …` call
  site is validated against the schema allowlists; dangling (unreferenced)
  fields are reported.
- `pipeline review` — LLM `code-review` rules (subjective conventions a compiler
  can't express; see `library/`).
- `pipeline docs` — regenerates the at-a-glance tables (pipeline → stage →
  system → component → field → subject) from the schema.

See `SCHEMA.md` for the runtime persistence/component API, and the agent
conventions in `node_modules/agl-ai/docs/MICROAGENT.md` (the single authoritative
copy, shipped by the `agl-ai` dependency).
for the microagent conventions.
