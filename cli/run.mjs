// pipeline run — run the project's agent loop.
//
// Prefers the project's own agent.coffee (the customization hook — projects can
// extend or replace the loop there). When absent, falls back to the framework's
// batteries-included default entry (bin/run-default.coffee → runPipeline), so a
// plain activity-only project still runs without any boilerplate file.

import { spawn } from 'child_process'
import { resolve, dirname } from 'path'
import { existsSync } from 'fs'
import { fileURLToPath } from 'url'
import { acquireLock, forwardSignals, wantsBypass, stripLockFlags } from './lock.mjs'

export default async function run(args) {
  // Single-process lock for this directory (shared with `pipeline walk`).
  const bypass = wantsBypass(args)
  acquireLock('run', { bypass })
  args = stripLockFlags(args)

  const projectEntry = resolve(process.cwd(), 'agent.coffee')
  let entry
  if (existsSync(projectEntry)) {
    entry = projectEntry
  } else {
    // Framework default — bin/run-default.coffee lives next to this cli/ dir.
    const here = dirname(fileURLToPath(import.meta.url))
    entry = resolve(here, '..', 'bin', 'run-default.coffee')
    console.error('No agent.coffee found — running the framework default loop (runPipeline). Add an agent.coffee to customize.')
  }
  // cwd stays the project so its bunfig preload (coffeescript) + _G.ROOT resolve.
  const child = spawn('bun', [entry, ...args], { stdio: 'inherit', cwd: process.cwd() })
  forwardSignals(child)
  child.on('exit', (code) => process.exit(code ?? 0))
  child.on('error', (err) => { console.error(String(err)); process.exit(1) })
}
