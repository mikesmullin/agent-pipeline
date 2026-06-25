// pipeline docs — regenerate at-a-glance reference tables from the schema,
// manifests, config, system header comments, and Gate() markers.
//
// Modes (auto-detected):
//  • MULTI-ACTIVITY (activities/*.yaml present): one docs/<id>/PIPELINE.md per
//    activity + a top-level docs/ACTIVITIES.md listing.
//  • SINGLE-ACTIVITY (root config.yaml with systems:): docs/REFERENCE.md.
//
// Each PIPELINE.md contains four generated tables:
//  1. Pipeline Stages   — # (manifest order, whole numbers) · System · Purpose
//                         (Purpose = the system header's first comment paragraph)
//  2. Gate Logic        — System · Gate label · Condition (extracted verbatim
//                         from Gate(...) markers in the system source)
//  3. Entity Schema     — Field · Type · Description
//  4. Access Control    — Subject · Fields it may access (INVERTED: one row
//                         per subject)
//
// Generated files are OWNED by autodoc and overwritten wholesale on each run.
// Keep any hand-written prose in a SEPARATE adjacent file (e.g.
// docs/<id>/NOTES.md) — the generator never touches non-generated files.
//
// Flags:  --suffix <s>   write PIPELINE<s>.md / ACTIVITIES<s>.md / REFERENCE<s>.md
//                        (e.g. --suffix .generated) for side-by-side review.

import { readFile, readdir, mkdir, writeFile } from 'fs/promises'
import { resolve, relative } from 'path'
import { load as yamlLoad } from 'js-yaml'

const ROOT = resolve(process.cwd())
const esc = (s) => String(s ?? '').replace(/\|/g, '\\|').replace(/\n+/g, ' ').trim()
const code = (s) => '`' + String(s).replace(/`/g, '\u200b`') + '`'

// ── Schema (one file → { components, scalars }) ──────────────────────────────
function loadSchema(data) {
  const components = {}, scalars = {}
  for (const [cn, c] of Object.entries(data.components ?? {}))
    components[cn] = { description: c.description, array: !!c.array, fields: c.fields ?? {} }
  for (const [n, d] of Object.entries(data.scalars ?? {})) scalars[n] = d
  return { components, scalars }
}

// ── System header comment → { purpose } ──────────────────────────────────────
// Convention: leading `#` comment block. Optional title line (e.g.
// "fetchSystem" or "fetchSystem — Stage 1"). The PURPOSE is the FIRST paragraph
// (contiguous comment lines) after the title line — paragraphs are separated by
// a blank comment line (`#` alone). Authors put a 1-sentence + 1-paragraph
// summary as that first block, then a blank `#` line, then any longer notes.
function systemPurpose(text) {
  const raw = []
  for (const line of text.split('\n')) {
    const m = line.match(/^\s*#(.*)$/)
    if (m) { raw.push(m[1].replace(/^ /, '')); continue }
    if (line.trim() === '') { if (raw.length) break; else continue }
    break
  }
  if (!raw.length) return ''
  // Drop a leading title-only line (no sentence punctuation, or "— Stage N").
  let i = 0
  const first = raw[0].trim()
  const looksTitle = /^[\w.-]+(System)?(\s+—\s+Stage\s+\S+)?$/.test(first) || /—\s*Stage\s+/i.test(first)
  if (looksTitle) i = 1
  // Skip blank comment lines before the first paragraph.
  while (i < raw.length && raw[i].trim() === '') i++
  // Collect the first paragraph (until the next blank comment line).
  const para = []
  for (; i < raw.length; i++) {
    if (raw[i].trim() === '' || /^-{3,}$/.test(raw[i].trim())) break
    para.push(raw[i].trim())
  }
  return para.join(' ').trim()
}

// ── Gate() extraction from a system source ───────────────────────────────────
// Returns [{ label, cond, line }]. Matches both `Gate cond` and `Gate(label,
// ── Gate() extraction from a system source ───────────────────────────────────
// Returns [{ label, cond, line }]. Captures both `Gate cond` and `Gate(label,
// cond)` call forms, including conditions that span MULTIPLE lines (read until
// parentheses balance), collapsed to a single line. The string label becomes the
// "Requirement"; the expression becomes the "Condition".
function extractGates(text) {
  const lines = text.split('\n')
  const stripComment = (s) => s.replace(/\s+#(?!\{).*$/, '')
  const bal = (s) => { let b = 0; for (const c of s) { if (c === '(') b++; else if (c === ')') b-- } return b }
  const out = []
  for (let i = 0; i < lines.length; i++) {
    const line0 = lines[i]
    if (/^\s*#/.test(line0)) continue             // comment line
    if (/^\s*import\b/.test(line0)) continue       // import statement
    const m = line0.match(/\bGate\b(\s*\(\s*|\s+)(?![},)])/)
    if (!m) continue
    const explicit = m[1].includes('(')
    let acc = stripComment(line0.slice(m.index + m[0].length))
    let balance = (explicit ? 1 : 0) + bal(acc)
    let j = i
    while (balance > 0 && j + 1 < lines.length) {   // gather a multi-line condition
      j++
      const nxt = stripComment(lines[j])
      acc += ' ' + nxt.trim()
      balance += bal(nxt)
    }
    let args = acc.trim()
    if (explicit && args.endsWith(')')) args = args.slice(0, -1).trim()
    let label = null, cond = args
    const lm = args.match(/^(['"])((?:\\.|(?!\1).)*)\1\s*,\s*([\s\S]*)$/)
    if (lm) { label = lm[2]; cond = lm[3].trim() }
    cond = cond.replace(/\s+/g, ' ').replace(/\(\s+/g, '(').replace(/\s+\)/g, ')').trim()
    if (cond && !/^[},]/.test(cond)) out.push({ label, cond, line: i + 1 })
  }
  return out
}

const systemNameToFile = (name) =>
  name.replace(/System$/, '').replace(/([A-Z])/g, (_, c) => '-' + c.toLowerCase()).replace(/^-/, '')

// ── Render one activity's PIPELINE.md ────────────────────────────────────────
async function renderActivity(a) {
  const { id, name, description, schema, pipeline } = a
  const L = []
  L.push(`# ${name ?? id} — Pipeline & Schema Reference`)
  L.push('')
  L.push('> Generated by `pipeline docs`. Do not edit — hand-written prose belongs in a separate adjacent file.')
  L.push('')
  if (description) { L.push(esc(description)); L.push('') }
  L.push(`Activity: ${code(id)}`)
  L.push('')

  // Read each system's source once.
  const sources = {}
  for (const s of pipeline) {
    const file = `systems/${id}/${systemNameToFile(s.name)}.coffee`
    sources[s.name] = { file, text: await readFile(resolve(ROOT, file), 'utf8').catch(() => '') }
  }

  // 1. Pipeline Stages — Purpose only (no gate logic here).
  L.push('## Pipeline Stages')
  L.push('')
  L.push('| # | System | Purpose |')
  L.push('|---|--------|---------|')
  pipeline.forEach((s, i) => {
    const { file, text } = sources[s.name]
    L.push(`| ${i + 1} | [${code(s.name)}](../../${file}) | ${esc(systemPurpose(text)) || '—'} |`)
  })
  L.push('')

  // 2. Gate Logic — extracted Gate() markers (the "why is it stuck?" reference).
  L.push('## Gate Logic')
  L.push('')
  L.push('Each row is a requirement an entity must satisfy to be processed by the system, with the')
  L.push('exact condition extracted verbatim from a `Gate(...)` marker. Use this to debug an entity')
  L.push('stuck in / skipped by a stage. (The framework `Entity.query` applies the `pipelineWidth`')
  L.push('cap; it is not a system gate.)')
  L.push('')
  L.push('| System | Requirement | Condition |')
  L.push('|--------|-------------|-----------|')
  let anyGate = false
  for (const s of pipeline) {
    const gates = extractGates(sources[s.name].text)
    for (const g of gates) {
      anyGate = true
      L.push(`| ${code(s.name)} | ${g.label ? esc(g.label) : '—'} | ${code(g.cond)} |`)
    }
  }
  if (!anyGate) L.push('| — | — | *(no `Gate()` markers found)* |')
  L.push('')

  // 3. Entity Schema — Field / Type / Description.
  L.push('## Entity Schema')
  L.push('')
  L.push('Fields use dot notation `<component>.<field>` (array components show `[]`).')
  L.push('')
  L.push('| Field | Type | Description |')
  L.push('|-------|------|-------------|')
  for (const [n, d] of Object.entries(schema.scalars))
    L.push(`| ${code(n)} | ${esc(d.type)} | ${esc(d.description)} |`)
  for (const [cn, c] of Object.entries(schema.components)) {
    const prefix = c.array ? `${cn}[]` : cn
    for (const [fn, fd] of Object.entries(c.fields)) {
      const field = fd.rev0_only ? `${cn}[0].${fn}` : `${prefix}.${fn}`
      L.push(`| ${code(field)} | ${esc(fd.type)} | ${esc(fd.description)} |`)
    }
  }
  L.push('')

  // 4. Access Control — INVERTED: one row per subject → fields it may access.
  const subjectFields = {}
  const add = (subj, field) => { (subjectFields[subj] ??= new Set()).add(field) }
  for (const [n, d] of Object.entries(schema.scalars))
    for (const s of (d.subjects ?? [])) add(s, n)
  for (const [cn, c] of Object.entries(schema.components))
    for (const [fn, fd] of Object.entries(c.fields))
      for (const s of (fd.subjects ?? [])) add(s, `${cn}.${fn}`)
  L.push('## Access Control (by subject)')
  L.push('')
  L.push('Each caller (subject) and the component fields it is authorized to access. See `docs/SCHEMA.md` for the prefix conventions.')
  L.push('')
  L.push('| Subject | Fields |')
  L.push('|---------|--------|')
  for (const subj of Object.keys(subjectFields).sort())
    L.push(`| ${code(subj)} | ${[...subjectFields[subj]].sort().map(code).join(', ')} |`)
  return L.join('\n')
}

function renderActivityList(activities) {
  const L = []
  L.push('# Activities')
  L.push('')
  L.push('> Generated by `pipeline docs`.')
  L.push('')
  L.push('Pipelines hosted by this project. One row per `activities/*.yaml`.')
  L.push('')
  L.push('| Activity | Name | Stages | Systems | Agents | Reference |')
  L.push('|----------|------|--------|---------|--------|-----------|')
  for (const a of activities)
    L.push(`| ${code(a.id)} | ${esc(a.name)} | ${esc((a.stages ?? []).join(', '))} | ${a.pipeline.length} | ${(a.agents ?? []).length} | [${code(`docs/${a.id}/PIPELINE.md`)}](${a.id}/PIPELINE.md) |`)
  return L.join('\n')
}

async function loadActivities() {
  const dir = resolve(ROOT, 'activities')
  let files
  try { files = (await readdir(dir)).filter((f) => f.endsWith('.yaml')) } catch { return [] }
  const out = []
  for (const f of files) {
    const cfg = yamlLoad(await readFile(resolve(dir, f), 'utf8')) ?? {}
    if (!cfg.id) continue
    let schema = { components: {}, scalars: {} }
    if (cfg.schemaFile) {
      try { schema = loadSchema(yamlLoad(await readFile(resolve(ROOT, cfg.schemaFile), 'utf8')) ?? {}) } catch {}
    }
    const pipeline = (cfg.pipeline ?? []).map((s) => (typeof s === 'string' ? { name: s } : s))
    const agents = (cfg.agents ?? cfg.microagents ?? []).map((x) => (typeof x === 'string' ? x : x.name))
    out.push({ id: cfg.id, name: cfg.name, description: cfg.description, stages: cfg.stages, schema, pipeline, agents })
  }
  return out
}

async function renderSingle() {
  let cfg = {}
  for (const name of ['config.yaml', 'config.yaml.example']) {
    try { cfg = yamlLoad(await readFile(resolve(ROOT, name), 'utf8')) ?? {}; break } catch {}
  }
  const systems = (cfg.systems ?? []).map((s, i) => {
    const e = typeof s === 'string' ? { name: s } : s
    return { name: e.name, weight: e.weight ?? (i + 1) * 10 }
  }).sort((x, y) => x.weight - y.weight)

  const SCHEMA_DIR = resolve(ROOT, 'schema')
  let schemaFiles = []
  try { schemaFiles = (await readdir(SCHEMA_DIR)).filter((f) => f.endsWith('.yaml')) } catch {}
  const merged = { components: {}, scalars: {} }
  for (const f of schemaFiles) {
    const s = loadSchema(yamlLoad(await readFile(resolve(SCHEMA_DIR, f), 'utf8')) ?? {})
    Object.assign(merged.components, s.components); Object.assign(merged.scalars, s.scalars)
  }

  const L = []
  L.push(`# ${cfg.name ?? 'Pipeline'} — Reference`)
  L.push('')
  L.push('> Generated by `pipeline docs`.')
  L.push('')
  L.push('## Pipeline Stages')
  L.push('')
  L.push('| # | System | Purpose |')
  L.push('|---|--------|---------|')
  for (let i = 0; i < systems.length; i++) {
    const text = await readFile(resolve(ROOT, `systems/${systems[i].name}.coffee`), 'utf8').catch(() => '')
    L.push(`| ${i + 1} | ${code(systems[i].name)} | ${esc(systemPurpose(text)) || '—'} |`)
  }
  L.push('')
  L.push('## Gate Logic')
  L.push('')
  L.push('| System | Requirement | Condition |')
  L.push('|--------|-------------|-----------|')
  let any = false
  for (const s of systems) {
    const text = await readFile(resolve(ROOT, `systems/${s.name}.coffee`), 'utf8').catch(() => '')
    for (const g of extractGates(text)) { any = true; L.push(`| ${code(s.name)} | ${g.label ? esc(g.label) : '—'} | ${code(g.cond)} |`) }
  }
  if (!any) L.push('| — | — | *(no `Gate()` markers found)* |')
  L.push('')
  L.push('## Entity Schema')
  L.push('')
  L.push('| Field | Type | Description |')
  L.push('|-------|------|-------------|')
  for (const [n, d] of Object.entries(merged.scalars)) L.push(`| ${code(n)} | ${esc(d.type)} | ${esc(d.description)} |`)
  for (const [cn, c] of Object.entries(merged.components))
    for (const [fn, fd] of Object.entries(c.fields))
      L.push(`| ${code(`${cn}.${fn}`)} | ${esc(fd.type)} | ${esc(fd.description)} |`)
  return L.join('\n')
}

async function write(path, body) {
  await mkdir(resolve(path, '..'), { recursive: true })
  await writeFile(path, body.replace(/\n*$/, '') + '\n', 'utf8')
}

export default async function docs(args = []) {
  const si = args.indexOf('--suffix')
  const suffix = si >= 0 ? (args[si + 1] ?? '') : ''
  const activities = await loadActivities()

  if (activities.length > 0) {
    for (const a of activities) {
      const path = resolve(ROOT, 'docs', a.id, `PIPELINE${suffix}.md`)
      await write(path, await renderActivity(a))
      console.log(`Wrote ${relative(ROOT, path)}  (${a.pipeline.length} stages, ${Object.keys(a.schema.components).length} components)`)
    }
    const listPath = resolve(ROOT, 'docs', `ACTIVITIES${suffix}.md`)
    await write(listPath, renderActivityList(activities))
    console.log(`Wrote ${relative(ROOT, listPath)}  (${activities.length} activities)`)
    return
  }

  const path = resolve(ROOT, 'docs', `REFERENCE${suffix}.md`)
  await write(path, await renderSingle())
  console.log(`Wrote ${relative(ROOT, path)}`)
}
