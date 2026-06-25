# Persistence & Component API

How entities are stored, loaded, mutated, and queried at runtime. Read
`ARCHITECTURE.md` first for the contract; this is the API reference.

## Entity (static class)

```coffeescript
import { Entity } from 'pipeline'

await Entity.init()                       # load db/, start the chokidar watcher (the loop does this)
entity = await Entity.load id             # cache if mtime unchanged, else reload from disk; stub if absent
saved  = await Entity.save entity         # write db/<id>.yaml (strips _mtime/_path)

await Entity.patch    entity, 'note', { text }            # replace a component
await Entity.merge    entity, 'review', { _approved_by }  # shallow-merge into a component
await Entity.append   entity, 'debug._log', line          # append to an array component
await Entity.setPath  entity, 'workflow._status', 'x'     # set a nested dot-path
await Entity.drop     entity, ['convert', 'verify']       # remove keys → re-queue / rewind
await Entity.transition entity, 'converted', { _status: 'in_progress' }
await Entity.recordError entity, err                      # increments workflow._retry_count
Entity.inBackoff entity                                   # true while in post-error backoff window
Entity.generateId seed                                    # 7-char SHA1 git-style id
```

The disk is authoritative. Every `load` goes through the model and re-reads from
disk when the file's mtime changed, so operator edits in an editor take effect on
the next loop tick.

## World (cache + query)

```coffeescript
import { World } from 'pipeline'   # or _G.World

World.Entity__find (e) -> e.workflow?._stage is 'captured'   # the core query primitive
World.get id
World.all()
World.count()
```

Systems **pull** their work via `Entity__find`. They are never handed entities.

## Components (validated accessors)

Declare the component + fields (with `subjects:` allowlists) in `schema/*.yaml`,
then build a model:

```coffeescript
import { defineComponent } from 'pipeline'
export NoteComponent = defineComponent 'note', ['text', 'seen_at']
```

`defineComponent` generates a validated getter (`camelCase(field)`) and setter
(`set` + `PascalCase(field)`) per field. Every accessor's first arg is the
calling subject:

```coffeescript
SYSTEM = 'system:my-entity/echo'
text = await NoteComponent.text SYSTEM, id           # getter
await NoteComponent.setSeenAt SYSTEM, id, isoNow      # setter
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
