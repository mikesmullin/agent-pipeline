// pipeline new <name> — scaffold a complete, runnable pipeline project.
//
// Produces a minimal but end-to-end project: an `ingest` system that turns
// lines dropped into db/_drop.md into entities, and an `echo` system that
// advances them — both using a schema-validated NoteComponent so `pipeline
// check` and `pipeline docs` have something real to work with.

import { mkdir, writeFile, readFile } from 'fs/promises'
import { resolve } from 'path'
import { existsSync } from 'fs'

const file = (root, rel, content) => writeFile(resolve(root, rel), content, 'utf8')

export default async function neu(args) {
  const name = args[0]
  if (!name) { console.error('Usage: pipeline new <name>'); process.exit(1) }
  const root = resolve(process.cwd(), name)
  if (existsSync(root)) { console.error(`Refusing to overwrite existing path: ${root}`); process.exit(1) }

  const entity = name.replace(/[^a-z0-9]+/gi, '-').toLowerCase()

  for (const d of ['schema', 'systems', 'microagents', 'models/components', 'docs', 'db'])
    await mkdir(resolve(root, d), { recursive: true })

  await file(root, 'package.json', JSON.stringify({
    name, type: 'module', private: true,
    scripts: { start: 'bun agent.coffee', check: 'pipeline check', docs: 'pipeline docs' },
    dependencies: { 'pipeline': 'link:pipeline', 'agl-ai': '^0.1.4', 'bun-coffeescript': '^1.0.3', 'chokidar': '^5.0.0', 'js-yaml': '^4.1.1' },
  }, null, 2) + '\n')

  await file(root, 'bunfig.toml', 'preload = ["bun-coffeescript/register"]\n')

  await file(root, '.gitignore', 'node_modules/\ndb/\n*.log\nagent.pid\n.code-review/\n.DS_Store\n')

  await file(root, 'config.yaml', `# ${name} — pipeline config
name: ${name}
model: copilot:claude-sonnet-4.6
pipeline_width: 3
loop_interval_ms: 5000

retry:
  max_count: 5
  backoff_ms: 60000

# Systems run in ascending weight order each loop tick. Omit weight to use
# declaration order (10, 20, 30 ...).
systems:
  - name: ingest
  - name: echo
`)

  await file(root, 'agent.coffee', `# ${name} — agent entry point.
# The loop body is nothing but system calls; runPipeline() owns the engine tick.
import { runPipeline } from 'pipeline'

await runPipeline()
`)

  await file(root, `schema/${entity}.yaml`, `# Single source of truth for the ${entity} entity.
#
# Each field's subjects[] list is the canonical allowlist. A caller not in the
# list is rejected at runtime (fatal) when it accesses the field via its
# component model. The SchemaValidator reads this file fresh on every call.

entity: ${entity}

scalars:
  id:
    type: string
    description: "Short SHA1 id. Write-once at creation."
    subjects: [system:${entity}/ingest, system:${entity}/echo]

# NOTE: pipeline bookkeeping (workflow._stage/_status/_retry_count) is written
# by Entity.transition / Entity.recordError at the framework level, NOT through a
# component model — so it is intentionally absent from this schema.
components:

  # The example payload component.
  note:
    description: "A single dropped note."
    fields:
      text:
        type: string
        description: "The note text the operator dropped into db/_drop.md."
        subjects: [system:${entity}/ingest, system:${entity}/echo]
      seen_at:
        type: "ISO string | null"
        description: "When the echo system processed this note."
        subjects: [system:${entity}/echo]
`)

  await file(root, 'models/components/note.coffee', `# NoteComponent — validated accessors for entity.note.*
# Generated from the schema field list; see schema/${entity}.yaml.
import { defineComponent } from 'pipeline'

export NoteComponent = defineComponent 'note', ['text', 'seen_at']
export default NoteComponent
`)

  await file(root, 'systems/ingest.coffee', `# ingestSystem
#
# Promotes lines dropped into db/_drop.md into pipeline entities, up to
# pipelineWidth per tick. This is the first system: it reconciles the operator
# drop-zone into the World so everything downstream can query by component presence.
import { readFile, writeFile } from 'fs/promises'
import { resolve } from 'path'
import { _G, Entity } from 'pipeline'
import { NoteComponent } from '../models/components/note.coffee'

SYSTEM = 'system:${entity}/ingest'
_DROP = -> resolve _G.DB_DIR, '_drop.md'

export ingestSystem = ->
  try
    text = await readFile _DROP(), 'utf8'
  catch
    return   # no drop file yet  # gate:ignore
  notes = text.split(/\\n-{3,}\\n/).map((s) -> s.trim()).filter (s) -> s.length
  return unless notes.length   # gate:ignore (input presence, not an entity gate)

  batch = notes[0..._G.pipelineWidth]
  for noteText in batch
    id = Entity.generateId noteText + Date.now()
    _G.currentEntityId = id
    entity = await Entity.load id
    entity = await Entity.transition entity, 'captured'
    await NoteComponent.setText SYSTEM, id, noteText
    _G.log 'ingested', { id, text: noteText.slice 0, 40 }

  # Consume the promoted notes from the top of the drop file.
  remaining = notes[batch.length...]
  await writeFile _DROP(), remaining.join('\\n\\n---\\n\\n'), 'utf8'

export default ingestSystem
`)

  await file(root, 'systems/echo.coffee', `# echoSystem
#
# The example downstream system: stamps note.seen_at and advances entities to
# 'done'. It selects entities at stage 'captured' via Entity.query (an archetype
# query) and is a template for how a real system gates, reads/writes components,
# and transitions.
#
# Note the Gate(...) marker around the gate logic. Entity.query owns the
# pipelineWidth cap (a framework default, not system gate logic). A predicate
# matches UNLESS it returns false — so falling through the guards = a match.
import { _G, Entity, Gate } from 'pipeline'
import { NoteComponent } from '../models/components/note.coffee'

SYSTEM = 'system:${entity}/echo'

export echoSystem = ->
  targets = await Entity.query (e) ->
    return false unless Gate 'captured & not in backoff', e.workflow?._stage is 'captured' and not Entity.inBackoff e

  for entity in targets
    _G.currentEntityId = entity.id
    try
      text = await NoteComponent.text SYSTEM, entity.id
      await NoteComponent.setSeenAt SYSTEM, entity.id, new Date().toISOString()
      _G.log 'echo', { text }
      await Entity.transition entity, 'done', { _status: 'completed' }
    catch err
      await Entity.recordError entity, err

export default echoSystem
`)

  await file(root, 'microagents/.gitkeep', '')

  await file(root, '.code-review.yaml', `# LLM-powered convention rules for this pipeline. Run:  pipeline review
#
# The bundled framework rules (microagent + gate + ECS conventions) live in the
# 'pipeline' package's library/pipeline.code-review.yaml. These local rules can
# add project-specifics.

- id: microagent-conventions
  description: Microagents follow the focus-not-size MICROAGENT conventions.
  matches:
    - "microagents/**/*.coffee"
  prompt: |
    Use the read_file tool to read the conventions doc at:
      node_modules/agl-ai/docs/MICROAGENT.md
    The given file is a microagent. Return pass=false if it violates a
    convention (e.g. more than one decision per wrapper, a bloated system
    prompt, field semantics duplicated outside the output schema, deterministic
    work done inside the model). Name the specific convention in the rationale.
`)

  await file(root, 'README.md', `# ${name}

An agent pipeline built on the [\`pipeline\`](../pipeline) framework.

## Run

\`\`\`sh
bun install            # ensure the linked 'pipeline' dep resolves
bun agent.coffee       # or: pipeline run
\`\`\`

Drop work into \`db/_drop.md\` (sections delimited by \`---\`):

\`\`\`markdown
first note

---

second note
\`\`\`

## Develop

\`\`\`sh
pipeline check     # static schema/ACL linter
pipeline review    # LLM convention rules
pipeline docs      # regenerate docs/REFERENCE.md from the schema
pipeline status    # per-stage entity snapshot
\`\`\`

See \`docs/REFERENCE.md\` (generated) for the stage → system → component → field tables.
`)

  await file(root, 'db/_drop.md', 'hello pipeline\n\n---\n\nsecond example note\n')

  console.log(`Scaffolded ${name}/`)
  console.log('Next:')
  console.log(`  cd ${name}`)
  console.log(`  bun link pipeline      # link the framework from local disk`)
  console.log(`  bun install`)
  console.log(`  pipeline check && pipeline docs`)
  console.log(`  bun agent.coffee`)
}
