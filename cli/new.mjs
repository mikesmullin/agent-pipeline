// pipeline new <project> [--activity <id> [--stages a,b,c]] ... — scaffold a
// complete, runnable, ACTIVITY-FIRST project.
//
// Everything is multi-activity. A single-activity project is just a project with
// one activity in the list — the structure is identical, so you never refactor
// when a second activity arrives.
//
// CLI — ordered, repeatable scope flags (short to type, easy to read):
//   The FIRST positional is the project dir. Then `--activity <id>` opens a
//   scope; flags that follow apply to THAT activity until the next `--activity`.
//   Repeat `--activity` to add more.
//
//   pipeline new myproj                                 # one activity 'myproj', default stages
//   pipeline new myproj --activity kibana --stages ingest,resolve,publish,verify,report
//   pipeline new bigproj \
//     --activity kibana --stages ingest,resolve,publish,verify,report \
//     --activity beam   --stages fetch,convert,publish
//
// Each activity gets: <project>/<id>/{activity.yaml, schema.yaml, config.yaml,
// systems/<stage>.coffee (one per stage, chained), models/components/note.coffee,
// microagents/, agents/, docs/, db/_drop.md}. The project root gets package.json,
// bunfig.toml, agent.coffee, config.yaml (loop knobs only), .gitignore,
// .code-review.yaml, README.md. Fresh scaffold passes `pipeline check` and runs.

import { mkdir, writeFile } from 'fs/promises'
import { resolve } from 'path'
import { existsSync } from 'fs'

const file = (root, rel, content) => writeFile(resolve(root, rel), content, 'utf8')

// --- naming helpers ---------------------------------------------------------
const slug = (s) => String(s).replace(/[^a-z0-9]+/gi, '-').replace(/^-+|-+$/g, '').toLowerCase()
const camel = (s) => slug(s).replace(/-([a-z0-9])/g, (_, c) => c.toUpperCase())
const title = (s) => slug(s).split('-').map(w => w.charAt(0).toUpperCase() + w.slice(1)).join(' ')
const fnName = (stage) => camel(stage) + 'System'          // ingestSystem, findDataviewSystem
const splitCsv = (s) => String(s ?? '').split(',').map(x => slug(x)).filter(Boolean)

const die = (msg) => { console.error(`pipeline new: ${msg}`); process.exit(1) }

const USAGE = `pipeline new <project> [--activity <id> [--stages a,b,c]] ...

  <project>                 the project directory to create
  --activity <id>           open a scope for activity <id> (repeatable, ordered)
  --stages a,b,c            the pipeline stages for the current activity
                            (the first stage ingests; the rest chain in order)

Examples:
  pipeline new notes
  pipeline new kib --activity kibana --stages ingest,resolve,publish,verify,report
  pipeline new big --activity kibana --stages ingest,publish,verify \\
                   --activity beam   --stages fetch,convert,publish
`

// --- arg parsing: ordered, repeatable --activity scopes ---------------------
function parseArgs(args) {
  if (!args.length || args[0].startsWith('-')) { process.stdout.write(USAGE); process.exit(args.length ? 1 : 0) }
  const project = args[0]
  const activities = []
  let cur = null
  for (let i = 1; i < args.length; i++) {
    const a = args[i]
    switch (a) {
      case '--activity': {
        const id = slug(args[++i] ?? '')
        if (!id) die('--activity requires an id')
        if (activities.some(x => x.id === id)) die(`duplicate activity '${id}'`)
        cur = { id, stages: null }
        activities.push(cur)
        break
      }
      case '--stages':
        if (!cur) die('--stages must follow an --activity')
        cur.stages = splitCsv(args[++i])
        if (!cur.stages.length) die('--stages requires a comma-separated list')
        break
      case '--help': case '-h':
        process.stdout.write(USAGE); process.exit(0)
      default:
        die(`unexpected argument: ${a}`)
    }
  }
  // No --activity given → one activity named after the project.
  if (!activities.length) activities.push({ id: slug(project), stages: null })
  // Default stages for any activity that didn't specify them.
  for (const act of activities) if (!act.stages?.length) act.stages = ['ingest', 'process']
  return { project, activities }
}

// --- per-activity file generation -------------------------------------------
// Build the schema for one activity. `text` is written by the ingest stage;
// `processed_at` by every processing stage (or by ingest when single-stage).
function schemaYaml(id, stages) {
  const subj = (s) => `system:${id}/${s}`
  const allSubjects = stages.map(subj)
  const ingest = stages[0]
  const processors = stages.slice(1)
  const textSubjects = [subj(ingest)]
  const procSubjects = processors.length ? processors.map(subj) : [subj(ingest)]
  return `# Schema for the '${id}' entity — the single source of truth for its
# components + per-field access control. Each field's subjects[] is the
# allowlist; a caller not listed is rejected at runtime (fatal) and flagged by
# 'pipeline check'. The SchemaValidator re-reads this file on every call.
#
# Replace 'note' with your real domain components as you build the activity out.

entity: ${id}

scalars:
  id:
    type: string
    description: "Short SHA1 id. Write-once at creation."
    subjects: [${allSubjects.join(', ')}]

# NOTE: framework bookkeeping (workflow._stage/_status/_retry_count) is written
# by Entity.transition / Entity.recordError — NOT through a component model — so
# it is intentionally absent here.
components:

  note:
    description: "Example payload component — replace with your domain components."
    fields:
      text:
        type: string
        description: "The note text dropped into ${id}/db/_drop.md."
        subjects: [${textSubjects.join(', ')}]
      processed_at:
        type: "ISO string | null"
        description: "When a processing stage last advanced this entity."
        subjects: [${procSubjects.join(', ')}]
`
}

function activityYaml(id, stages) {
  // Decorative stage labels = the stage basenames; pipeline = the fn names.
  // Path fields (entityDir/schemaFile/configFile/docsDir) are OMITTED on purpose
  // so the activity-first defaults apply (<id>/db, <id>/schema.yaml, ...). An
  // explicit stale path here is a classic footgun (the indexer finds 0 entities).
  return `# Activity manifest for '${id}'. Activity-first layout: everything for this
# activity lives under ${id}/. Paths are inferred (db/, schema.yaml, config.yaml,
# docs/, systems/, microagents/, agents/) — declare them only to override.
id:    ${id}
name:  ${title(id)}

# Decorative phase labels (for dashboards/counts). The loop runs the pipeline
# below in order regardless of these.
stages: [${stages.join(', ')}]

# Ordered pipeline systems — exported fn names from systems/<basename>.coffee
# (fooBarSystem -> foo-bar.coffee).
pipeline:
${stages.map(s => `  - ${fnName(s)}`).join('\n')}

# Agents (the microagent subset + any chat/multi-tool agents). Add as you need a
# subjective LLM decision: { name, path } or a bare string for microagents/<name>.
agents: []
`
}

function ingestSystem(id, stages) {
  const stage = stages[0]
  const next = stages[1] ?? 'done'
  const single = stages.length === 1
  const setProcessed = single
    ? `\n    await NoteComponent.setProcessedAt SYSTEM, ACTIVITY, id, new Date().toISOString()`
    : ''
  const transitionExtra = next === 'done' ? `, { _status: 'completed' }` : ''
  return `# ${fnName(stage)} — stage 1 of '${id}': ingest (the SOURCE system).
#
# Pulls lines dropped into ${id}/db/_drop.md into entities (up to pipelineWidth
# per tick) and advances them to the next stage. Replace this with a real
# upstream fetch (an API, a queue, Jira, Kibana, ...) when you build the activity
# out — the shape stays the same: read upstream, create/transition entities.
#
# Every Entity / component call takes the activity id first (ACTIVITY).
import { readFile, writeFile } from 'fs/promises'
import { resolve } from 'path'
import { _G, Entity, Activities } from 'pipeline'
import { NoteComponent } from '../models/components/note.coffee'

SYSTEM   = 'system:${id}/${stage}'
ACTIVITY = '${id}'
NEXT     = '${next}'
_DROP    = -> resolve Activities.entityDir(ACTIVITY), '_drop.md'

export ${fnName(stage)} = ->
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
    entity = await Entity.load ACTIVITY, id
    entity = await Entity.transition ACTIVITY, entity, NEXT${transitionExtra}
    await NoteComponent.setText SYSTEM, ACTIVITY, id, noteText${setProcessed}
    _G.log 'ingested', { id, text: noteText.slice 0, 40 }

  # Consume the promoted notes from the top of the drop file.
  remaining = notes[batch.length...]
  await writeFile _DROP(), remaining.join('\\n\\n---\\n\\n'), 'utf8'

export default ${fnName(stage)}
`
}

function processSystem(id, stages, idx) {
  const stage = stages[idx]
  const next = stages[idx + 1] ?? 'done'
  const n = idx + 1
  const transitionExtra = next === 'done' ? `, { _status: 'completed' }` : ', {}'
  return `# ${fnName(stage)} — stage ${n} of '${id}'.
#
# Template for a real stage: SELECT the entities this stage owns via Entity.query
# (an archetype query — match by component presence / status), do deterministic
# work (or delegate the ONE subjective call to a microagent), write components,
# then transition. The gate here reads only workflow._stage, so the Entity.query
# line is marked '# index:ignore' (full-body selection by design). A stage that
# gates on a component field instead declares 'export GATE_FIELDS = [...]' so the
# low-memory field-index can project just those (and 'pipeline check' verifies it).
import { _G, Entity, Gate } from 'pipeline'
import { NoteComponent } from '../models/components/note.coffee'

SYSTEM   = 'system:${id}/${stage}'
ACTIVITY = '${id}'
NEXT     = '${next}'

export ${fnName(stage)} = ->
  targets = await Entity.query ACTIVITY, (e) ->   # index:ignore — gate reads workflow._stage, not a component field
    return false unless Gate 'at stage ${stage}, not in backoff', e.workflow?._stage is '${stage}' and not Entity.inBackoff e

  for entity in targets
    _G.currentEntityId = entity.id
    try
      await NoteComponent.setProcessedAt SYSTEM, ACTIVITY, entity.id, new Date().toISOString()
      _G.log '${stage}', { id: entity.id }
      await Entity.transition ACTIVITY, entity, NEXT${transitionExtra}
    catch err
      await Entity.recordError ACTIVITY, entity, err

export default ${fnName(stage)}
`
}

async function scaffoldActivity(root, id, stages) {
  for (const d of ['systems', 'microagents', 'agents', 'models/components', 'docs', 'db'])
    await mkdir(resolve(root, id, d), { recursive: true })

  await file(root, `${id}/activity.yaml`, activityYaml(id, stages))
  await file(root, `${id}/schema.yaml`, schemaYaml(id, stages))
  await file(root, `${id}/config.yaml`, `# ${id} — per-activity DOMAIN config (read by this activity's systems, e.g.
# API endpoints, target spaces, thresholds). Framework LOOP knobs (model,
# pipeline_width, loop_interval_ms, ...) live in the ROOT config.yaml instead.
`)
  await file(root, `${id}/models/components/note.coffee`, `# NoteComponent — validated accessors for the '${id}' entity's note.* fields.
# Generated from the schema field list; see ${id}/schema.yaml.
import { defineComponent } from 'pipeline'

export NoteComponent = defineComponent 'note', ['text', 'processed_at']
export default NoteComponent
`)

  // One system file per stage. First = ingest (source); rest = chained processors.
  await file(root, `${id}/systems/${stages[0]}.coffee`, ingestSystem(id, stages))
  for (let i = 1; i < stages.length; i++)
    await file(root, `${id}/systems/${stages[i]}.coffee`, processSystem(id, stages, i))

  await file(root, `${id}/microagents/.gitkeep`, '')
  await file(root, `${id}/agents/.gitkeep`, '')
  await file(root, `${id}/docs/.gitkeep`, '')
  await file(root, `${id}/db/_drop.md`, `hello ${id}\n\n---\n\nsecond example note\n`)
}

// --- entry ------------------------------------------------------------------
export default async function neu(args) {
  const { project, activities } = parseArgs(args)
  const root = resolve(process.cwd(), project)
  if (existsSync(root)) die(`refusing to overwrite existing path: ${root}`)
  await mkdir(root, { recursive: true })

  // Root project files (loop-level, shared by all activities).
  await file(root, 'package.json', JSON.stringify({
    name: slug(project), type: 'module', private: true,
    scripts: { start: 'bun agent.coffee', check: 'pipeline check', docs: 'pipeline docs' },
    dependencies: { 'pipeline': 'link:pipeline', 'agl-ai': '^0.1.4', 'bun-coffeescript': '^1.0.3', 'chokidar': '^5.0.0', 'js-yaml': '^4.1.1' },
  }, null, 2) + '\n')

  await file(root, 'bunfig.toml', 'preload = ["bun-coffeescript/register"]\n')

  // db/ lives PER ACTIVITY (<id>/db/); ignore them all.
  await file(root, '.gitignore', 'node_modules/\n*/db/\n*.log\ndebug.log\nagent.pid\n.pipeline.lock\n.code-review/\n.DS_Store\n')

  await file(root, 'agent.coffee', `# ${project} — agent entry point.
# The loop body is nothing but runPipeline(): it discovers every <id>/activity.yaml,
# runs each activity's pipeline each tick, and owns the engine (PID guard, graceful
# shutdown, field-index, the 'pipeline walk' debug harness).
import { runPipeline } from 'pipeline'

await runPipeline()
`)

  // Root config = LOOP KNOBS ONLY (no systems: list — that's activity-first's job).
  await file(root, 'config.yaml', `# ${project} — framework loop knobs (apply across all activities).
name: ${project}
model: copilot:claude-sonnet-4.6
pipeline_width: 3
loop_interval_ms: 5000
parallel_activities: true   # run each activity's pipeline in parallel per tick

retry:
  max_count: 5
  backoff_ms: 60000
`)

  await file(root, '.code-review.yaml', `# LLM convention rules for this pipeline. Run:  pipeline review
#
# The framework's shared rules (microagent + gate + ECS + schema/ACL conventions)
# are INHERITED from the 'pipeline' dependency via the include below. Add
# project-specific rules under 'rules:' (redeclare an inherited id to override).
include:
  - node_modules/pipeline/library/*.code-review.yaml

rules: []
`)

  const actList = activities.map(a => `- **${a.id}** — \`${a.stages.join(' → ')}\``).join('\n')
  await file(root, 'README.md', `# ${project}

An agent pipeline built on the [\`pipeline\`](../pipeline) framework.
Activity-first layout — one directory per activity:

${actList}

## Run

\`\`\`sh
bun link pipeline      # resolve the linked 'pipeline' dep from local disk
bun install
bun agent.coffee       # or: pipeline run
\`\`\`

Each activity ingests from \`<id>/db/_drop.md\` (sections delimited by \`---\`).

## Develop

\`\`\`sh
pipeline check                          # static schema/ACL + gate + field-index linter
pipeline docs                           # regenerate per-activity docs/PIPELINE.md
pipeline walk --activity <id> --once    # walk entities through stages (debug harness)
pipeline status                         # per-stage entity snapshot
\`\`\`
`)

  for (const act of activities) await scaffoldActivity(root, act.id, act.stages)

  // --- report ---------------------------------------------------------------
  console.log(`Scaffolded ${project}/  (${activities.length} ${activities.length === 1 ? 'activity' : 'activities'})`)
  for (const a of activities) console.log(`  • ${a.id}: ${a.stages.join(' → ')}`)
  console.log('Next:')
  console.log(`  cd ${project}`)
  console.log(`  bun link pipeline      # link the framework from local disk`)
  console.log(`  bun install`)
  console.log(`  pipeline check && pipeline docs`)
  console.log(`  bun agent.coffee`)
}
