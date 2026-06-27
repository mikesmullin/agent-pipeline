# Activities — Parallel Pipelines (the framework standard)

This document is part of the **general pipeline standard**. It defines the
*Activity* concept — how one pipeline project can host several independent
pipelines side by side — and the **extensible manifest** that describes each
one. Read `ARCHITECTURE.md` (the ECS contract) and `SCHEMA.md` (the component /
ACL contract) first; this layers the multi-pipeline abstraction on top.

Anything implementation-specific (a particular activity's domain, a UI, a
mascot) is **not** part of this standard — see §8 "Extension points".

---

## 1 — Mental model

An **Activity** is one named pipeline a project can run. A project may host one
activity or many; they execute independently over their own entities. The
user-facing concept (Activity) sits one level above the runtime concept (entity
kind); today the mapping is 1:1, which keeps reasoning simple and scales by
repetition.

```
Activity (declared in activities/<id>.yaml)
  • id            stable identifier used everywhere (URLs, dirs, schema lookups)
  • name          human-readable label
  • stages        decorative phase labels for dashboards/counts
  └─ resolves to ─┐
Entity kind (machine-facing)
  • schemaFile    schema/<id>.yaml           (component + ACL contract)
  • entityDir     db/entities/<id>/          (one YAML per entity)
  • configFile    db/config/<id>/config.yaml (per-activity runtime knobs)
  • docsDir       docs/<id>/                 (per-activity docs)
  • pipeline      [fetchSystem, …]           (ordered systems)
  • agents        [01-…, 02-…]               (agents incl. the microagent subset)
```

Adding an activity is **YAML + files, not code** — declare a manifest, drop in
the systems/agents/schema it references, and the registry wires it up at startup.

---

## 2 — Standard directory layout

A scaffolded pipeline (see `pipeline new`) follows this convention. Per-activity
folders are namespaced by the activity `id`.

```
activities/
  <id>.yaml                       ← one manifest per activity

schema/
  <id>.yaml                       ← per-entity-kind schema (component + ACL)

systems/
  <id>/                           ← one folder per activity
    fetch.coffee  …  publish.coffee

microagents/                      ← the microagent SUBSET (focused, one-question agents)
  <id>/
    01-….coffee
  shared/                         ← shared agent helpers (not agents themselves)

agents/                           ← the agent SUPERSET that are NOT microagents
  <id>/                           ← e.g. conversational/multi-tool chat assistants
    02-chat.coffee

models/
  entity.coffee                   ← persistence primitives
  components/
    schema-validator.coffee
    <component>.coffee            ← one validated component model per component

db/
  entities/<id>/<entity>.yaml     ← per-activity entity files (source of truth)
  config/<id>/config.yaml         ← per-activity runtime config
                                    (project-global files, e.g. auth, live here too)

docs/
  ARCHITECTURE.md  SCHEMA.md  ACTIVITY.md   ← (link the framework standard)
  <id>/PIPELINE.md                          ← generated reference (pipeline docs)

agent.coffee                      ← the headless loop driver (runPipeline)
```

> **Agents vs. microagents.** `microagents/` holds the *focused subset* (one
> question → one typed tool call). Other agents (conversational, multi-tool,
> multi-decision) live in `agents/`. Both are "agents" in the manifest and in
> subject identity (`agent:<id>/<label>`); only `microagents/**` is held to the
> microagent contract by the convention rules. See `MICROAGENT.md`.

---

## 2a — Activity-first layout (the grouped alternative)

The framework also supports an **activity-first** layout that groups *everything
for one activity under a single directory* — instead of namespacing each kind
(`systems/<id>/`, `schema/<id>.yaml`, `db/entities/<id>/`) by activity. The two
layouts are equivalent to the framework (it is **dual-mode** — it discovers and
loads both, and they may even coexist during a migration); pick whichever reads
better for your project. Activity-first scales nicely when activities are
genuinely independent (separate teams, schemas, entity stores).

```
<project root>/
  <activity-id>/                  ← one directory per activity (the grouping)
    activity.yaml                 ← the manifest (id, stages, pipeline, agents)
    schema.yaml                   ← per-activity schema (component + ACL)
    config.yaml                   ← per-activity runtime knobs
    systems/   fetch.coffee … publish.coffee
    microagents/  01-….coffee
    agents/    02-chat.coffee
    docs/      PIPELINE.md (generated)
    db/        <entity>.yaml       ← per-activity entity files (source of truth)
  shared/                         ← cross-activity helpers (NOT an activity; skipped)
  agent.coffee                    ← the headless loop driver
```

**Discovery (zero-config, by glob).** `Activities.loadAll()` treats every
top-level directory that contains an `activity.yaml` as one activity (`shared/`
and dot-dirs are skipped). When the manifest omits a path, these **defaults**
apply, all resolved relative to the activity directory:

| Manifest field | Activity-first default |
|---|---|
| `entityDir` | `<activity>/db` |
| `schemaFile` | `<activity>/schema.yaml` |
| `configFile` | `<activity>/config.yaml` |
| `docsDir` | `<activity>/docs` |
| systems | `<activity>/systems/<module>.coffee` |
| microagents | `<activity>/microagents/<name>.coffee` |
| agents (bare string) | `<activity>/agents/<name>.coffee` |

So a minimal `activity.yaml` need only declare `id`, `name`, `stages`,
`pipeline`, and `agents` — the rest is inferred from the directory.

**Tooling is layout-agnostic.** `SchemaValidator` unions every activity's
`schema.yaml` (just as it unions the legacy central `schema/*.yaml`), and
`pipeline check` scans each `<activity>/{systems,microagents,agents}` and reads
each `<activity>/schema.yaml`. The legacy central layout (§2) keeps working
unchanged; if a project has a central `schema/` dir or an `activities/` dir, that
takes precedence and the activity-first scan is additive.

---

## 3 — The activity manifest

`activities/<id>.yaml` is the single declarative description of an activity.

```yaml
id:          my-activity            # stable id (NOT the filename); used in URLs, dirs, schema
name:        My Activity            # human-readable label
description: |
  What this pipeline converts / does.

# Paths (relative to project root).
schemaFile:  schema/my-activity.yaml
entityDir:   db/entities/my-activity
configFile:  db/config/my-activity/config.yaml
docsDir:     docs/my-activity

# Decorative stage labels for dashboards / human-facing counts. The agent loop
# runs the `pipeline` functions below in order regardless of these labels.
stages: [original, converted, published]

# Ordered pipeline systems. Each entry is an exported function name from
# systems/<id>/<modulename>.coffee. Module filename = name with trailing
# "System" stripped and hyphenated: fetchSystem -> fetch.coffee,
# adminApproveSystem -> admin-approve.coffee.
pipeline:
  - fetchSystem
  - convertSystem
  - publishSystem

# Agents (superset) imported at startup. Each registers itself on _G when
# imported. `name` is the registration label; `path` (relative to project root)
# lets an agent live anywhere — microagents under microagents/, other agents
# under agents/. A bare string is shorthand for microagents/<id>/<name>.coffee.
agents:
  - name: 01-convert
    path: microagents/my-activity/01-convert.coffee
  - name: 02-chat
    path: agents/my-activity/02-chat.coffee

# Optional: theme color for any UI a project chooses to build.
themeColor:  '#6366f1'

# Optional: dot-paths in the entity body that arrive as opaque JSON-encoded
# strings from the upstream source; expanded on fetch / compacted on publish.
# jsonStringFields:
#   - attributes.panelsJSON
```

### Field reference

| Field | Required | Standard? | Purpose |
|---|---|---|---|
| `id` | yes | standard | Activity id used everywhere. From this key, **not** the filename. |
| `name` | yes | standard | Human label. |
| `description` | no | standard | Free text. |
| `schemaFile` | yes¹ | standard | Path to the entity schema. |
| `entityDir` | yes¹ | standard | Where entity YAMLs persist. |
| `configFile` | yes¹ | standard | Per-activity runtime config. |
| `docsDir` | yes¹ | standard | Per-activity docs dir. |
| `stages` | no | standard | Decorative phase labels. |
| `pipeline` | yes | standard | Ordered system function names. A system may `export GATE_FIELDS = [...]` (the `<component>.<field>` dot-paths its gate reads); the union across the pipeline is the activity's field-index (see ARCHITECTURE #14). |
| `agents` | yes | standard | Agents to import (incl. the microagent subset). `{name, path}` or bare string. |
| `jsonStringFields` | no | standard | JSON-string dot-paths to expand/compact. |
| `themeColor` | no | standard (extension-friendly) | Accent color for an optional UI. |
| *(others)* | — | **extension** | Implementation-specific keys (e.g. a mascot). See §8. |

> ¹ Required in the **legacy central** layout; **optional in the activity-first**
> layout (§2a), where they default to `<activity>/{schema.yaml,db,config.yaml,docs}`.

`Activities` is a static class with a registry built once at startup.

```coffeescript
await Activities.loadAll()      # call once at startup (agent + any server)
Activities.all()                # array of loaded activities
Activities.get('my-activity')   # one activity (or throws)
Activities.ids()                # ['my-activity', …]
```

`loadAll()` walks `activities/*.yaml`, reads each manifest, then **dynamically
imports** each named system module (resolving function-name → file-name by
hyphenation) and each agent module (by its explicit `path`). Agents register
themselves on `_G` as a side effect of being imported.

### CoffeeScript dynamic-import gotcha

CoffeeScript treats `import` as a static keyword and won't parse
`await import(path)`. Use JS backtick-passthrough:

```coffeescript
moduleUrl = pathToFileURL(modulePath).href
mod = await `import(moduleUrl)`
```

### The loaded activity object

```javascript
{
  id, name, description,
  schemaFile, entityDir, configFile, docsDir,   // resolved to absolute paths
  themeColor,
  stages:   ['original', 'converted', 'published'],
  pipeline: [{ name: 'fetchSystem', fn: <function> }, …],  // resolved fns
  agents:   ['01-convert', '02-chat'],                     // registration labels
  jsonStringFields: [],
  // …any extension fields a project added to its manifest…
}
```

---

## 5 — The headless agent loop

The general pipeline is **headless**. `agent.coffee` is a minimal driver that
runs each activity's systems in order each tick:

```coffeescript
await Activities.loadAll()
for activity in Activities.all()
  await _G.Entity.init activity.id

while not _G.quit
  for activity in Activities.all()
    for step in activity.pipeline
      await step.fn()
  await _G.sleep LOOP_INTERVAL_MS
```

Activities run **sequentially** within a tick by default (predictable logs,
no cross-activity contention). Parallelism can be added as `Promise.all` over
the activity loop without touching the systems.

The disk is authoritative: each stage commits via component setters, and the
next stage re-reads from disk (the runtime SchemaValidator also reads
`schema/*.yaml` on every call, so schema edits hot-reload).

---

## 6 — What's NOT in the standard

- **No UI.** The only cross-pipeline contract is *entities live on disk as YAML*.
  A pipeline may ship zero, one, or many UIs; a UI is "compatible" iff it
  reads/writes those YAML files. UIs are the primary creative expression of an
  individual pipeline and are documented **per project**, not here.
- **No per-activity Entity / validator / route classes.** `Entity` and the
  `SchemaValidator` are shared; each takes `activityId` (or resolves it from the
  component's schema file). Shared components appearing in multiple schemas have
  their `subjects[]` allowlists UNIONed.
- **No domain knowledge.** Conversion guides, business rules, and the like are
  per-activity proprietary docs.

---

## 7 — Checking activities

`pipeline check` validates that every component accessor call site uses a
subject in the schema's `subjects[]` allowlist, across `systems/`,
`microagents/`, and `agents/`. It understands the `system:` / `agent:` /
`route:` subject prefixes and the `#{activityId}` template expansion used by
multi-activity route handlers. See `SCHEMA.md` for the check semantics.

---

## 8 — Extension points (the extensible standard)

The activity *shape* is standard, but a pipeline may add its own manifest keys
and conventions. The standard reserves no namespace — unknown keys are carried
through onto the loaded activity object untouched — so a project documents its
extensions in its **own** `docs/`, not here.

Typical extensions (examples, not part of the standard):

| Extension | What it adds | Documented in |
|---|---|---|
| `themeColor` / accent | UI theming | standard slot, project UI docs |
| `mascotDir` / `avatarName` | A chat-agent avatar / mascot | the project's docs |
| Any `*UI*` / route config | A web or other UI | the project's docs |

The rule of thumb: if a key describes *how this pipeline presents or extends
itself*, it's an extension (project docs). If it describes *the pipeline's data,
stages, agents, or contract*, it's standard (this doc).

---

## References

- ECS + invariants — `ARCHITECTURE.md`
- Component / schema / ACL / validation — `SCHEMA.md`
- Agent vs. microagent — `node_modules/agl-ai/docs/MICROAGENT.md`
- Generated per-activity reference tables — `docs/<id>/PIPELINE.md` (via `pipeline docs`)
