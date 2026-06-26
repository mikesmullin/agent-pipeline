// pipeline check — static schema/ACL linter.
//
// Scans the project's systems/ and microagents/ .coffee files for component
// accessor call sites of the form:
//
//     ComponentName.method 'subject', ...     (or  ComponentName.method SUBJECT, ...)
//
// and validates each against schema/*.yaml:
//   - component exists
//   - the field implied by the method exists
//   - the subject string is in that field's subjects[] allowlist
//
// Method→field convention: getter = camelCase(field), setter = set+PascalCase(field).
// Compound/multi-field methods can be declared in an optional schema-aliases.yaml
// at the project root:   ComponentName.method: [field1, field2]
//
// Also reports schema fields that no call site references (dangling).
// Exit code 1 if any call site is invalid.

import { readFile, readdir, stat } from 'fs/promises'
import { resolve } from 'path'
import { load as yamlLoad } from 'js-yaml'

const ROOT = resolve(process.cwd())
const SCHEMA_DIR = resolve(ROOT, 'schema')

const G = '\x1b[32m', R = '\x1b[31m', Y = '\x1b[33m', D = '\x1b[2m', X = '\x1b[0m'

const camel = (s) => s.replace(/_([a-z])/g, (_, c) => c.toUpperCase())
const pascal = (s) => { const c = camel(s); return c.charAt(0).toUpperCase() + c.slice(1) }

async function listCoffee(dir) {
  const out = []
  let entries
  try { entries = await readdir(dir) } catch { return out }
  for (const e of entries) {
    const p = resolve(dir, e)
    let s
    try { s = await stat(p) } catch { continue }
    if (s.isDirectory()) out.push(...await listCoffee(p))
    else if (e.endsWith('.coffee')) out.push(p)
  }
  return out
}

export default async function check() {
  // ── Load schemas ──────────────────────────────────────────────────────────
  let schemaFiles
  try { schemaFiles = (await readdir(SCHEMA_DIR)).filter(f => f.endsWith('.yaml')) }
  catch { console.error(`${R}No schema/ dir found at ${SCHEMA_DIR}${X}`); process.exit(1) }
  if (!schemaFiles.length) { console.error(`${R}No schema files in ${SCHEMA_DIR}${X}`); process.exit(1) }

  const components = {}   // name → { fields: {f:{subjects[]}}, schemaFile }
  const scalars = {}
  for (const f of schemaFiles) {
    const path = resolve(SCHEMA_DIR, f)
    const data = yamlLoad(await readFile(path, 'utf8')) ?? {}
    for (const [cname, c] of Object.entries(data.components ?? {})) {
      const existing = components[cname]
      if (existing) {
        const merged = { ...existing.fields }
        for (const [fn, fd] of Object.entries(c.fields ?? {})) {
          const ef = merged[fn]
          merged[fn] = ef
            ? { ...ef, ...fd, subjects: [...new Set([...(ef.subjects ?? []), ...(fd.subjects ?? [])])] }
            : fd
        }
        components[cname] = { fields: merged, schemaFile: path }
      } else {
        components[cname] = { fields: c.fields ?? {}, schemaFile: path }
      }
    }
    for (const [name, def] of Object.entries(data.scalars ?? {})) {
      const ex = scalars[name]
      scalars[name] = ex
        ? { def: { ...ex.def, ...def, subjects: [...new Set([...(ex.def.subjects ?? []), ...(def.subjects ?? [])])] }, schemaFile: path }
        : { def, schemaFile: path }
    }
  }

  // ── Optional compound-method aliases ───────────────────────────────────────
  let aliases = {}
  try { aliases = yamlLoad(await readFile(resolve(ROOT, 'schema-aliases.yaml'), 'utf8')) ?? {} } catch {}

  // ── Build accessor → field(s) map ──────────────────────────────────────────
  const accessorMap = {}        // ClassName → { component, methods: { method: [fields] } }
  const fieldUsage = new Map()  // "component.field" → count
  for (const [cname, c] of Object.entries(components)) {
    const cls = pascal(cname) + 'Component'
    accessorMap[cls] = { component: cname, methods: {} }
    for (const fname of Object.keys(c.fields)) {
      fieldUsage.set(`${cname}.${fname}`, 0)
      accessorMap[cls].methods[camel(fname)] = [fname]
      accessorMap[cls].methods['set' + pascal(fname)] = [fname]
    }
  }
  for (const [key, fields] of Object.entries(aliases)) {
    const [cls, method] = key.split('.')
    if (accessorMap[cls]) accessorMap[cls].methods[method] = Array.isArray(fields) ? fields : [fields]
  }

  console.log(`Schema files: ${schemaFiles.map(f => `schema/${f}`).join(', ')}\n`)

  // ── Scan source ─────────────────────────────────────────────────────────────
  // systems/ + microagents/ + agents/ (the agent superset) are the standard
  // dirs that hold validated component accessors; a top-level server.coffee (if
  // present) carries route:* handlers that also access components.
  const sourceFiles = [
    ...await listCoffee(resolve(ROOT, 'systems')),
    ...await listCoffee(resolve(ROOT, 'microagents')),
    ...await listCoffee(resolve(ROOT, 'agents')),
  ]
  for (const extra of ['server.coffee']) {
    const p = resolve(ROOT, extra)
    try { await stat(p); sourceFiles.push(p) } catch {}
  }

  // ── Activity-template expansion ─────────────────────────────────────────────
  // A shared route/agent handler may build its subject as a template, e.g.
  // `route:#{activityId}/:uid/edit` or `agent:#{activityId}/chat`, to serve every
  // activity with one handler. Expand `#{activityId}` (and the JS `${activityId}`
  // form) to each concrete activity id from activities/*.yaml and require the
  // resulting subject to be allowed for ALL activities. Strings without the
  // placeholder pass through unchanged.
  const activityIds = []
  for (const f of (await readdir(resolve(ROOT, 'activities')).catch(() => []))) {
    if (!f.endsWith('.yaml')) continue
    try { const c = yamlLoad(await readFile(resolve(ROOT, 'activities', f), 'utf8')); if (c?.id) activityIds.push(c.id) } catch {}
  }
  const expandSubject = (subject) => {
    if (!/[#$]\{activityId\}/.test(subject)) return [subject]
    if (!activityIds.length) return [subject]
    return activityIds.map((id) => subject.replace(/[#$]\{activityId\}/g, id))
  }

  const CALL_RE = /\b([A-Z][A-Za-z]+Component)\.([a-zA-Z_]\w*)\s*\(?\s*(?:['"]([^'"]+)['"]|([A-Za-z_]\w*))/g
  const SYSTEM_CONST_RE = /^\s*(?:const\s+|let\s+|var\s+)?(?:SYSTEM|SUBJECT)\s*=\s*['"]([^'"]+)['"]/m

  let valid = 0, invalid = 0
  const out = []

  for (const file of sourceFiles) {
    const text = await readFile(file, 'utf8').catch(() => null)
    if (text == null) continue
    const rel = file.replace(ROOT + '/', '')
    const sysMatch = text.match(SYSTEM_CONST_RE)
    const fileSubject = sysMatch ? sysMatch[1] : null
    const lines = text.split('\n')
    for (let i = 0; i < lines.length; i++) {
      let m; CALL_RE.lastIndex = 0
      while ((m = CALL_RE.exec(lines[i])) !== null) {
        const [, cls, method, lit, varName] = m
        const map = accessorMap[cls]
        if (!map) continue   // not a schema component class
        const fields = map.methods[method]
        if (!fields) {
          out.push(`${Y}?${X} ${rel}:${i + 1}  ${cls}.${method} — unknown method (add to schema-aliases.yaml)`)
          continue
        }
        // Resolve subject: a string literal, or the file-level SYSTEM/SUBJECT const.
        let subject = lit ?? (varName && /^(SYSTEM|SUBJECT)$/.test(varName) ? fileSubject : null)
        if (subject == null) continue   // dynamic subject we can't resolve — skip
        const subjects = expandSubject(subject)   // one per activity for #{activityId} templates
        let lineOk = true
        for (const field of fields) {
          const def = components[map.component].fields[field]
          fieldUsage.set(`${map.component}.${field}`, (fieldUsage.get(`${map.component}.${field}`) ?? 0) + 1)
          const allowed = def?.subjects ?? []
          for (const subj of subjects) {
            if (!allowed.includes(subj)) {
              lineOk = false
              out.push(`${R}✗${X} ${rel}:${i + 1}  ${subj} → ${map.component}.${field} ${D}(not in allowlist)${X}`)
            }
          }
        }
        if (lineOk) { valid++; out.push(`${G}✓${X} ${rel}:${i + 1}  ${subject} → ${map.component}.${fields.join(',')}`) }
        else invalid++
      }
    }
  }

  for (const line of out) console.log(line)

  // ── Gate-wrapper check ───────────────────────────────────────────────────────
  // Gate logic (entity-selection predicates + processing guards) must be wrapped
  // in the Gate(...) marker so it is enforceable, debuggable, and extractable by
  // `pipeline docs`. Flag gate-ish lines in systems that DON'T use Gate.
  //   - selection predicates: an Entity.query(...) / World.Entity__find / .find callback
  //   - guards: `continue|break|return false if/unless …`
  // A line already containing `Gate` is compliant. Lines marked with a trailing
  // `# gate:ignore` comment are exempted (rare, deliberate non-gate control flow).
  let gateViolations = 0
  const GUARD_RE = /\b(continue|break)\b.*\b(if|unless)\b|\breturn\s+false\b.*\b(if|unless)\b/
  const FIND_RE = /\b(Entity\.query|Entity__find|\.find)\s*\(?\s*\(?\s*(\(?\w*\)?)\s*->/
  for (const file of await listCoffee(resolve(ROOT, 'systems'))) {
    const text = await readFile(file, 'utf8').catch(() => null)
    if (text == null) continue
    const rel = file.replace(ROOT + '/', '')
    const lines = text.split('\n')
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i]
      if (/#\s*gate:ignore/.test(line)) continue
      if (/\bGate\b/.test(line)) continue
      const isGuard = GUARD_RE.test(line)
      const isFind = FIND_RE.test(line)
      if (isFind) {
        // The predicate body (with Gate) may be on the next line(s) when the
        // arrow opens a block. Look ahead a few lines for a Gate before flagging.
        const lookahead = lines.slice(i + 1, i + 4).join('\n')
        if (/\bGate\b/.test(lookahead) || /#\s*gate:ignore/.test(lookahead)) continue
      }
      if (isGuard || isFind) {
        gateViolations++
        const kind = isFind ? 'selection predicate' : 'guard'
        console.log(`${Y}⚠${X} ${rel}:${i + 1}  ${kind} not wrapped in Gate(...) ${D}→ ${line.trim().slice(0, 70)}${X}`)
      }
    }
  }
  if (gateViolations) console.log(`${Y}\n${gateViolations} gate-logic line(s) not wrapped in Gate(...)${X}`)

  // ── GATE_FIELDS index check ─────────────────────────────────────────────────
  // The field-index requires each Entity.query system to account for what its
  // gate reads. We enforce, like gate logic itself:
  //   (0) MANDATORY  — a system that calls Entity.query MUST either declare a
  //                    non-empty `export GATE_FIELDS = [...]`, OR carry an
  //                    explicit `# index:ignore` on the Entity.query line (an
  //                    intentional full-body stage whose gate reads heavy bodies).
  //                    Neither → error (no more silent skip of a forgotten index).
  //   (1) EXISTENCE  — every GATE_FIELDS entry is a real schema component.field.
  //   (2) COVERAGE   — every component field the gate predicate READS is in
  //                    GATE_FIELDS (else the projection won't carry it → silent
  //                    stuck/false-gate). A single read may be exempted with a
  //                    trailing `# index:ignore` on that read's line.
  //   (3) OVER-DECLARE (warn only) — a GATE_FIELDS entry the gate never reads.
  let indexErrors = 0
  const GATE_FIELDS_RE = /export\s+GATE_FIELDS\s*=\s*\[([^\]]*)\]/
  const QUERY_RE = /\bEntity\.query\b/
  for (const file of await listCoffee(resolve(ROOT, 'systems'))) {
    const text = await readFile(file, 'utf8').catch(() => null)
    if (text == null) continue
    const rel = file.replace(ROOT + '/', '')
    const lines = text.split('\n')

    // Does this system use Entity.query, and are any of those lines opted out?
    const queryLines = lines.filter(l => QUERY_RE.test(l))
    const usesQuery = queryLines.length > 0
    const allQueriesOptOut = usesQuery && queryLines.every(l => /#\s*index:ignore/.test(l))

    const gfMatch = text.match(GATE_FIELDS_RE)
    const declared = gfMatch ? [...gfMatch[1].matchAll(/['"]([^'"]+)['"]/g)].map(m => m[1]) : []

    // (0) Mandatory: a query system needs GATE_FIELDS or an explicit opt-out.
    if (usesQuery && declared.length === 0) {
      if (allQueriesOptOut) {
        console.log(`${D}—${X} ${rel}  Entity.query full-body (# index:ignore) — no GATE_FIELDS by design`)
      } else {
        indexErrors++
        console.log(`${R}✗${X} ${rel}  uses Entity.query but declares no GATE_FIELDS ${D}(add export GATE_FIELDS = [...], or mark the Entity.query line # index:ignore)${X}`)
      }
      continue
    }
    if (declared.length === 0) continue   // not a query system, nothing to index

    const declaredSet = new Set(declared)

    // (1) existence
    for (const dp of declared) {
      const [comp, field] = dp.split('.')
      if (!components[comp]?.fields?.[field]) {
        indexErrors++
        console.log(`${R}✗${X} ${rel}  GATE_FIELDS '${dp}' is not a schema component.field`)
      }
    }

    // Locate each Entity.query predicate block (indentation-scoped) and collect
    // the component fields it reads.
    const read = new Set()
    for (let i = 0; i < lines.length; i++) {
      if (!QUERY_RE.test(lines[i])) continue
      const baseIndent = lines[i].match(/^\s*/)[0].length
      for (let j = i + 1; j < lines.length; j++) {
        const ln = lines[j]
        if (ln.trim() === '') continue
        if (ln.match(/^\s*/)[0].length <= baseIndent) break   // dedent → end of predicate
        if (/#\s*index:ignore/.test(ln)) continue
        let m; CALL_RE.lastIndex = 0
        while ((m = CALL_RE.exec(ln)) !== null) {
          const [, cls, method] = m
          const mp = accessorMap[cls]
          if (!mp) continue
          const fields = mp.methods[method]
          if (!fields) continue
          for (const f of fields) read.add(`${mp.component}.${f}`)
        }
      }
    }

    // (2) coverage
    for (const dp of read) {
      if (!declaredSet.has(dp)) {
        indexErrors++
        console.log(`${R}✗${X} ${rel}  gate reads ${dp} but it is missing from GATE_FIELDS ${D}(add it, or mark the read # index:ignore)${X}`)
      }
    }
    // (3) over-declaration (warn)
    for (const dp of declared) {
      if (!read.has(dp)) console.log(`${Y}⚠${X} ${rel}  GATE_FIELDS '${dp}' not read by the gate ${D}(remove to keep the projection tight)${X}`)
    }
    if (read.size && [...read].every(dp => declaredSet.has(dp))) {
      console.log(`${G}✓${X} ${rel}  GATE_FIELDS covers the gate (${declared.length} field(s))`)
    }
  }

  // ── Dangling fields ─────────────────────────────────────────────────────────
  const dangling = [...fieldUsage.entries()].filter(([, n]) => n === 0).map(([k]) => k)
  if (dangling.length) {
    console.log(`\n${Y}Dangling fields (declared but no call site references them):${X}`)
    for (const k of dangling) console.log(`  ${D}- ${k}${X}`)
  }

  console.log(`\n${valid} valid, ${invalid} invalid, ${gateViolations} ungated, ${indexErrors} index, ${dangling.length} dangling`)
  process.exit(invalid > 0 || gateViolations > 0 || indexErrors > 0 ? 1 : 0)
}
