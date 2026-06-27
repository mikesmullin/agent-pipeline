#!/usr/bin/env bun
// pipeline — CLI entry / dispatcher.
//
// Usage:
//   pipeline new <name>                 scaffold a new pipeline project
//   pipeline g system|component|microagent <name>   scaffold one piece
//   pipeline check                      static schema/ACL linter
//   pipeline review [--pr <url>]        run LLM code-review rules
//   pipeline docs                       regenerate reference tables from schema
//   pipeline run                        run the agent loop (bun agent.coffee)
//   pipeline walk [selectors]           walk entities through stages (debug)
//   pipeline status                     per-stage entity snapshot
//   pipeline help

import { fileURLToPath } from 'url'
import { dirname, resolve } from 'path'

const __dirname = dirname(fileURLToPath(import.meta.url))
const CLI_DIR = resolve(__dirname, '..', 'cli')

const [, , cmd, ...args] = process.argv

const HELP = `pipeline — agent-pipeline framework CLI

  pipeline new <project> [--activity <id> [--stages a,b,c]] ...
                                           scaffold a new activity-first project.
                                           Repeat --activity to add activities;
                                           --stages scopes to the current one.
  pipeline g <kind> <name>                 generate system|component|microagent
      (aliases: generate, g)
  pipeline check                           static schema/ACL linter (exit 1 on violation)
  pipeline review [--pr <url>] [args...]   run LLM code-review rules
  pipeline docs                            regenerate at-a-glance reference tables
  pipeline run [args...]                   run the agent loop (bun agent.coffee)
  pipeline walk [selectors...]             walk a selection of entities through a
                                           selection of stages (dev/debug harness)
      --entity <id> | --entities <list|a..b|n..m>
      --stage <name> | --stages <list|a..b>
      --activity <glob>  --limit <n>  --verbose  --no-progress  --json
  pipeline status                          per-stage entity snapshot
  pipeline help
`

async function load(name) {
  const mod = await import(resolve(CLI_DIR, `${name}.mjs`))
  return mod.default
}

try {
  switch (cmd) {
    case 'new':       await (await load('new'))(args); break
    case 'g':
    case 'generate':  await (await load('generate'))(args); break
    case 'check':     await (await load('check'))(args); break
    case 'review':    await (await load('review'))(args); break
    case 'docs':      await (await load('docs'))(args); break
    case 'run':       await (await load('run'))(args); break
    case 'walk':      await (await load('walk'))(args); break
    case 'status':    await (await load('status'))(args); break
    case 'help':
    case '--help':
    case '-h':
    case undefined:   process.stdout.write(HELP); break
    default:
      process.stderr.write(`Unknown command: ${cmd}\n\n${HELP}`)
      process.exit(1)
  }
} catch (err) {
  process.stderr.write(`pipeline ${cmd}: ${err?.stack || err}\n`)
  process.exit(1)
}
