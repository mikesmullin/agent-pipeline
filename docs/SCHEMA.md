# Persistence & Component API

How entities are stored, loaded, mutated, and queried at runtime. Read
`ARCHITECTURE.md` first for the contract; this is the API reference.

> **Import surface.** Everything in this doc is the **DATA tier** — importable
> from either `pipeline` (the agent) or `pipeline/data` (a thin client / UI). The
> ECS-only orchestration (`Gate` / `runPipeline`) lives only in `pipeline`. See
> ARCHITECTURE.md § "Package surface (two tiers)".

> **Activity-scoped.** Every `Entity` / `World` / component accessor takes the
> **`activityId` first** (a project hosts one or many activities — see
> `ACTIVITY.md`). Single-activity projects pass the synthesized `'default'`
> activity (or rely on the default arg).

## Entity (static class)

```coffeescript
import { Entity } from 'pipeline'

await Entity.init activityId               # load that activity's dir, start its chokidar watcher (the loop does this)
entity = await Entity.load activityId, id   # full body, mtime-guarded; stub if absent
full   = await Entity.loadFull activityId, id  # force the full body (used internally on query-match)
saved  = await Entity.save activityId, entity  # write <entityDir>/<id>.yaml (strips _mtime/_path, LF-normalizes)

await Entity.patch    activityId, entity, 'note', { text }            # replace a component
await Entity.merge    activityId, entity, 'review', { _approved_by }  # shallow-merge into a component
await Entity.append   activityId, entity, 'debug._log', line          # append to an array component
await Entity.setPath  activityId, entity, 'workflow._status', 'x'     # set a nested dot-path
await Entity.drop     activityId, entity, ['convert', 'verify']       # remove keys → re-queue / rewind
await Entity.transition activityId, entity, 'converted', { _status: 'in_progress' }
await Entity.recordError activityId, entity, err                      # increments workflow._retry_count
Entity.inBackoff entity                    # true while in post-error backoff window

# Selection + lifecycle (the framework owns these; systems just call query)
targets = await Entity.query activityId, (e) -> …   # full entities, capped at pipelineWidth (see ARCHITECTURE Gate logic)
Entity.evict        activityId, id          # drop one body from the cache (streaming/memory)
Entity.evictHydrated activityId             # re-project this activity's hydrated set (field-index stage boundary)
Entity.exists       activityId, id          # has >=1 revision
Entity.allIds       activityId              # ids currently cached (F4-harness scoped)
Entity.snapshot     activityId, id          # read-only copy for the wire
await Entity.create activityId, id          # write an empty stub
Entity.generateId seed                      # 7-char SHA1 git-style id
```

The disk is authoritative. Every `load` goes through the model and re-reads from
disk when the file's mtime changed, so operator edits in an editor take effect on
the next loop tick.

## World (cache + query)

```coffeescript
import { World } from 'pipeline'   # or _G.World

W = World.for activityId                    # this activity's cache handle
W.Entity__find (e) -> e.workflow?._stage is 'captured'   # the core query primitive
W.get id
W.all()
W.count()
```

Systems **pull** their work via `Entity.query` (which uses `Entity__find`
underneath). They are never handed entities directly.

## Components (validated accessors)

Declare the component + fields (with `subjects:` allowlists) in `schema/*.yaml`,
then build a model:

```coffeescript
import { defineComponent } from 'pipeline'
export NoteComponent = defineComponent 'note', ['text', 'seen_at']
```

`defineComponent` generates a validated getter (`camelCase(field)`) and setter
(`set` + `PascalCase(field)`) per field. Every accessor takes the calling
**subject** then the **`activityId`** then the **id**:

```coffeescript
SYSTEM = 'system:my-entity/echo'
text = await NoteComponent.text SYSTEM, activityId, id            # getter
await NoteComponent.setSeenAt SYSTEM, activityId, id, isoNow      # setter
```

For compound/multi-field writes or array components, hand-roll a `Component`
subclass and call `@check(subject, field)` per field; declare the method→fields
mapping in `schema-aliases.yaml` so `pipeline check` can trace it.

## SchemaValidator

```coffeescript
import { SchemaValidator } from 'pipeline'
SchemaValidator.check  subject, component, field   # fatal (exit 1) if unauthorized
SchemaValidator.checkScalar subject, scalarName
```

Reads `schema/*.yaml` fresh on every call (no caching) so allowlist edits
hot-reload with no restart. Shared components declared in multiple schema files
have their `subjects[]` allowlists UNIONed.

## Field-index (opt-in low-memory selection)

When `_G.useFieldIndex` is true, the World holds thin **projections** (id + each
activity's indexed fields) instead of full entity bodies, so a large corpus does
not balloon RSS. See ARCHITECTURE invariant #14 for the model. Wiring:

- **Declare** per system: `export GATE_FIELDS = ['fetch.status', 'verify.pass', …]`
  — the `<component>.<field>` dot-paths that system's `Entity.query` gate reads.
  The activity's index is the **union** across its pipeline (`Activities` computes
  `activity._indexFields`). A system with no gate omits it; an activity where no
  system declares any stays in full-body mode.
- **Enable** in the loop driver: set `_G.useFieldIndex = true`, then call
  `Entity.evictHydrated activityId` after each stage fn (re-projects the hydrated
  working set — the stage-boundary GC).
- **Safety**: `Entity.load` returns a projection **only while a gate is scanning**;
  every other load (and so every write) sees a full body — writes never truncate.
- **Enforcement**: `pipeline check` requires every gate-read field to be in
  `GATE_FIELDS` (coverage) and to be a real schema field (existence); a read may
  be exempted with a trailing `# index:ignore`.

## Config (`config.yaml`)

| Key | Default | Purpose |
|-----|---------|---------|
| `name` | dir name | Display name in the loop banner. |
| `model` | `copilot:claude-sonnet-4.6` | Default microagent model. |
| `pipeline_width` | `3` | Max entities processed per stage per tick. |
| `loop_interval_ms` | `5000` | Sleep between full passes. |
| `concurrency` | `6` | agl-ai concurrency cap. |
| `retry.max_count` | `5` | Max retries before an entity stalls in place. |
| `retry.backoff_ms` | `60000` | Backoff window after each error. |
| `systems` | *(required)* | Ordered list; each entry `{ name, weight? }` (or a bare string). Lower weight runs first. |
