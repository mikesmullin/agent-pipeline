# 🔁 Agent Pipeline

**An ECS-inspired, disk-authoritative agent-pipeline framework for Bun + CoffeeScript.**

`pipeline` is the reusable contract behind agl-style microagent pipelines. It's a
game-engine-style loop: one long-running tick advances many **entities** through
**stages**, where each **system** pulls the entities it cares about, does
deterministic work, and delegates any single subjective judgment to a
**microagent**. All state is serialized to disk, so the loop is crash-safe,
operator-editable, and resumable.

The framework gives you the primitives **and** the guardrails — a runtime
`SchemaValidator` (per-field ACL), a static `pipeline check` linter, and a
bundled `code-review` rule set — so the conventions live in one place and are
*enforced*, not just documented.

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the full contract,
[`docs/SCHEMA.md`](docs/SCHEMA.md) for the runtime API, and
`node_modules/agl-ai/docs/MICROAGENT.md` for microagent conventions.

## Install (local, via `bun link`)

This package is not on npm yet. Link it from local disk:

```sh
cd tmp/pipeline
bun install
bun link            # registers the global `pipeline` binary + linkable dep
```

Then, in a project that should depend on it:

```sh
bun link pipeline   # resolves `import ... from 'pipeline'` to this local copy
```

## Quick start

```sh
pipeline new my-agent        # scaffold a complete, runnable project
cd my-agent
bun link pipeline
bun install
pipeline check               # static schema/ACL linter
pipeline docs                # generate docs/REFERENCE.md from the schema
bun agent.coffee             # run the loop (drops in db/_drop.md become entities)
```

## CLI

| Command | Purpose |
|---|---|
| `pipeline new <name>` | Scaffold a complete pipeline project. |
| `pipeline g system\|component\|microagent <name>` | Scaffold one piece, wired to the conventions. |
| `pipeline check` | Static schema/ACL linter (exit 1 on violation; reports dangling fields). |
| `pipeline review [--pr <url>]` | Run the LLM `code-review` convention rules. |
| `pipeline docs` | Regenerate the at-a-glance reference tables from the schema. |
| `pipeline run` | Run the agent loop (`bun agent.coffee`). |
| `pipeline status` | Per-stage entity snapshot. |

## Library API

```coffeescript
import { _G, Agent, Entity, Activities, World, SchemaValidator,
         Component, defineComponent, normalizeStrings, runPipeline } from 'pipeline'

# agent.coffee is just:
await runPipeline()
```

- **`Entity`** — disk-authoritative persistence, **activity-scoped** (every method
  takes `activityId` first): `load/loadFull/save/patch/merge/append/setPath/drop/
  transition/recordError/inBackoff/query/evict/evictHydrated/exists/allIds/
  snapshot/create/generateId`.
- **`Activities`** — the activity registry (`loadAll/get/all/ids/entityDir`);
  a project hosts one or many activities, or the synthesized `default`.
- **`World`** — per-activity cache via `World.for(activityId)` + the
  `Entity__find(predicate)` query primitive.
- **`SchemaValidator`** — runtime per-field ACL guard (fatal on violation).
- **`defineComponent(name, fields)`** — build a validated component model
  (accessors are `(subject, activityId, id)`).
- **`runPipeline()`** — the engine tick (config load, hot reload, PID guard,
  weighted systems, status summary).

## What's bundled

- `docs/` — `ARCHITECTURE.md`, `SCHEMA.md`, `ACTIVITY.md` (the contract).
  Microagent conventions are the single authoritative
  `node_modules/agl-ai/docs/MICROAGENT.md` (shipped by the `agl-ai` dependency,
  referenced by the rules).
- `library/pipeline.code-review.yaml` — shared convention rules, applied via
  `pipeline review`.

## Tests

```sh
bun test/unit.mjs
```
