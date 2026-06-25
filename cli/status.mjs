// pipeline status — per-stage entity snapshot read straight from db/*.yaml.

import { readFile, readdir } from 'fs/promises'
import { resolve, basename } from 'path'
import { load as yamlLoad } from 'js-yaml'

const D = '\x1b[2m', X = '\x1b[0m', B = '\x1b[1m', Y = '\x1b[33m', R = '\x1b[31m'

export default async function status() {
  const DB = resolve(process.cwd(), 'db')
  let files = []
  try { files = (await readdir(DB)).filter(f => f.endsWith('.yaml')) } catch {
    console.log('No db/ directory yet.'); return
  }
  const entities = []
  for (const f of files) {
    try {
      const e = yamlLoad(await readFile(resolve(DB, f), 'utf8')) ?? {}
      e.id ??= basename(f, '.yaml')
      entities.push(e)
    } catch {}
  }

  const byStage = {}
  let waiting = 0, errored = 0
  for (const e of entities) {
    const st = e.workflow?._stage ?? 'uncaptured'
    byStage[st] = (byStage[st] ?? 0) + 1
    if (e.workflow?._status === 'waiting_on_human') waiting++
    if ((e.workflow?._retry_count ?? 0) > 0) errored++
  }

  console.log(`${B}${entities.length}${X} entities`)
  for (const [st, n] of Object.entries(byStage).sort((a, b) => b[1] - a[1]))
    console.log(`  ${st.padEnd(28)} ${n}`)
  if (waiting) console.log(`${Y}  ${waiting} waiting on human${X}`)
  if (errored) console.log(`${R}  ${errored} with retry/error${X}`)
}
