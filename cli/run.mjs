// pipeline run — run the project's agent loop (bun agent.coffee).

import { spawn } from 'child_process'
import { resolve } from 'path'
import { existsSync } from 'fs'

export default async function run(args) {
  const entry = resolve(process.cwd(), 'agent.coffee')
  if (!existsSync(entry)) {
    console.error('No agent.coffee in the current directory. Run `pipeline new <name>` to scaffold one.')
    process.exit(1)
  }
  const child = spawn('bun', ['agent.coffee', ...args], { stdio: 'inherit', cwd: process.cwd() })
  child.on('exit', (code) => process.exit(code ?? 0))
  child.on('error', (err) => { console.error(String(err)); process.exit(1) })
}
