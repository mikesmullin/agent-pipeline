# 🔁 Agent Pipeline

**A framework for building agents that run as a loop, not a script.** Most "AI
agent" code is a one-shot prompt chain: it runs top to bottom, and when it
crashes halfway through a thousand items you start over and hope. `pipeline` is
the opposite. It borrows the **game-engine loop** — one long-running tick that
advances many work items a little at a time — and the **ECS pattern**
(entity / component / system) that game engines use to keep thousands of objects
organized. Your work items live on disk as plain YAML, so the loop is crash-safe,
resumable, and editable in your text editor while it runs.

The hard part of a real agent pipeline isn't calling the model — it's everything
around it: where does state live, which step runs next, who's allowed to write
which field, and how do you stop the model from quietly doing the wrong thing.
`pipeline` gives you those primitives **and** the guardrails. The LLM is confined
to tiny, single-decision **microagents**; everything else is deterministic code
the framework helps you keep honest with a runtime access-control check, a static
linter (`pipeline check`), and a generated reference doc that never goes stale.
You scaffold a project with one command and spend your time on business logic,
not plumbing.

**Why use it**

- **Crash-safe by construction.** State is YAML on disk, one file per work item.
  Kill the process mid-run and it resumes every item exactly where it left off.
- **The model can't go rogue.** Every component field declares who may write it;
  a violation is a hard error at runtime and a failed build under `pipeline check`.
- **Judgment is isolated.** LLM calls live only in one-decision microagents, so
  the rest of your pipeline is ordinary, testable, deterministic code.
- **Docs that stay true.** `pipeline docs` regenerates the stage / schema / access
  tables from the source, so the reference can't drift from the code.
- **Scaffold, don't memorize.** `pipeline new` and `pipeline g` write the
  boilerplate already wired to the conventions, so a new pipeline is mostly the
  part that's actually yours.

## Install

Built for [Bun](https://bun.sh) + CoffeeScript. Not on npm yet — link it from
local disk:

```sh
cd tmp/pipeline
bun install
bun link            # registers the global `pipeline` command + a linkable dep
```

## Build a pipeline

This is the part worth reading. `pipeline new` scaffolds a complete, runnable
project so you can see every concept in one place:

```sh
pipeline new my-agent
cd my-agent
bun link pipeline   # resolve `import … from 'pipeline'` to your local framework
bun install
```

You now have a working pipeline. Run it, then drop some work into its inbox:

```sh
bun agent.coffee                          # start the loop (ticks every few seconds)
echo "say hello" >> db/_drop.md           # hand it a unit of work
```

Debug a stage without running the whole loop — **walk** a selection of entities
through a selection of stages. A single entity prints its gate trace + component
diff; many entities stream one at a time under a live progress meter (spinner,
gradient bar, ETA):

```sh
pipeline walk --entity <id> --stage echoSystem        # one entity, one stage
pipeline walk --entities 0..49 --stages ingest..echo  # a range × a range of stages
pipeline walk                                         # all entities × all stages, once
```

Here's what the scaffold gives you, and the five ideas behind it:

- **Entity** — one unit of work, stored as `db/<id>.yaml`. It's just an `id` plus
  whatever data has accreted onto it. The starter project turns each line you drop
  into `db/_drop.md` into one entity.
- **Component** — a named, typed bag of fields on an entity (the starter ships a
  `note` component with `text` and `seen_at`). Components are declared once in
  `schema/<entity>.yaml`, which is also where you list **who may touch each
  field** — the access-control list the framework enforces.
- **System** — a function that advances entities through one stage. A system
  *pulls* the entities it cares about (it queries the world; it's never handed
  one), does deterministic work, and saves. The starter has two: `ingest` (drop
  file → entity) and `echo` (stamp `seen_at`).
- **Microagent** — the *only* place an LLM makes a decision: one question, one
  typed answer. The starter doesn't need one yet; you add them as the work gets
  subjective (`pipeline g microagent classify`).
- **The loop** — `agent.coffee` is one line, `await runPipeline()`. It runs your
  systems in order every tick. Nothing else lives in the loop body.

Generate the next piece already wired to the schema and conventions:

```sh
pipeline g system   enrich      # a new stage
pipeline g component triage     # a new typed field-bag (+ its ACL stub)
pipeline g microagent classify  # a one-decision LLM step
```

Keep it honest as you go:

```sh
pipeline check      # static schema/ACL linter — fails the build on a violation
pipeline docs       # regenerate the stage / schema / access reference from source
pipeline review     # run the bundled LLM convention rules (code-review)
```

Run `pipeline help` for the full command list.

## Using the library

Most of the time you only touch `agent.coffee`, which is just:

```coffeescript
import { runPipeline } from 'pipeline'

await runPipeline()
```

A **system** imports the few primitives it needs. Components are declared in the
schema and built with one line, then read/written through validated accessors —
each takes the calling **subject** (so the access-control check knows who's
asking) and the **activity** it belongs to:

```coffeescript
import { _G } from 'pipeline'
import { Entity } from 'pipeline'
import { defineComponent } from 'pipeline'

NoteComponent = defineComponent 'note', ['text', 'seen_at']

export echoSystem = ->
  # Pull the entities this stage cares about (never get handed one).
  targets = await Entity.query 'my-agent', (e) -> e.note? and not e.note.seen_at
  for entity in targets
    await NoteComponent.setSeenAt 'system:my-agent/echo', 'my-agent', entity.id, new Date().toISOString()
```

That's the whole shape: `Entity` is disk-authoritative persistence,
`defineComponent` gives you guarded accessors, and a project can host one
**activity** or many (each its own entity kind, schema, and entity dir).

## Documentation

Deeper reading, for when you want the full contract:

- [ARCHITECTURE](docs/ARCHITECTURE.md) — the ECS contract, the loop, the invariants, the `Gate` marker
- [SCHEMA](docs/SCHEMA.md) — persistence + component API + access control + the field-index
- [ACTIVITY](docs/ACTIVITY.md) — hosting multiple pipelines in one project; the activity manifest
- [MICROAGENT](https://github.com/mikesmullin/agl/blob/main/docs/MICROAGENT.md) — the one-decision LLM contract, shipped by the `agl-ai` dependency (also at `node_modules/agl-ai/docs/MICROAGENT.md`)
- [`library/pipeline.code-review.yaml`](https://github.com/mikesmullin/agent-pipeline/blob/main/library/pipeline.code-review.yaml) — the shared LLM convention rules `pipeline review` runs

## Contributing

The API is still settling, so expect
sharp edges and breaking changes. The fastest way to exercise a change end-to-end
is `pipeline new` a throwaway project against your working copy.

Run the unit tests (pure logic; no LLM, no network):

```sh
bun test/unit.mjs
```

