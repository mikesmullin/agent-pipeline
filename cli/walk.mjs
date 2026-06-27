// pipeline walk — walk a SELECTION of entities through a SELECTION of stages.
//
// The reusable dev/debug harness: run one entity (or a list, or a range) through
// one stage (or a list, or a range), with a live progress meter. Delegates to
// the project's agent.coffee so it runs in the project's real runtime (its
// globals, config, and bunfig preload), which routes the walk flags to the
// shared framework engine (runWalk).
//
// Examples:
//   pipeline walk --entity 002962 --stage findDataviewSystem --activity kibana-dashboard
//   pipeline walk --entities a1b2c3,d4e5f6 --stages findDataviewSystem..abTestSystem
//   pipeline walk --entities 0..99 --stage createDashboardSystem      # first 100 by id
//   pipeline walk                                                     # all entities × all stages, once
//
// Selectors (all optional; omit for "everything"):
//   --entity <id> | --entities <list|a..b|n..m>
//   --stage <name> | --stages <list|a..b>
//   --activity <glob>   --limit <n>   --verbose   --no-progress   --json

import { spawn } from 'child_process'
import { resolve } from 'path'
import { existsSync } from 'fs'

const WALK_FLAGS = ['--entity', '--entities', '--stage', '--stages', '--once']

export default async function walk(args) {
  const entry = resolve(process.cwd(), 'agent.coffee')
  if (!existsSync(entry)) {
    console.error('pipeline walk: no agent.coffee in the current directory.')
    console.error('cd into your pipeline project (or `pipeline new <name>` to scaffold one).')
    process.exit(1)
  }
  // Ensure walk mode even with no selectors: a bare `pipeline walk` means
  // "all entities × all stages, once" — which `--once` triggers in agent.coffee.
  const passthrough = WALK_FLAGS.some((f) => args.includes(f)) ? args : ['--once', ...args]
  const child = spawn('bun', ['agent.coffee', ...passthrough], { stdio: 'inherit', cwd: process.cwd() })
  child.on('exit', (code) => process.exit(code ?? 0))
  child.on('error', (err) => { console.error(String(err)); process.exit(1) })
}
