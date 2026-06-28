// pipeline review — run the LLM code-review rules against the project.
//
// Delegates to the `code-review` CLI (the LLM-powered convention linter). Tries
// a globally-linked `code-review` binary first, then `bunx code-review`, then
// `npx code-review`. All extra args (e.g. --pr <url>, --yaml) are passed through.

import { spawn } from 'child_process'

function run(cmd, args) {
  return new Promise((res) => {
    const child = spawn(cmd, args, { stdio: 'inherit', shell: false })
    child.on('error', () => res({ ok: false, code: 127 }))
    child.on('exit', (code) => res({ ok: code === 0, code: code ?? 1, spawned: true }))
  })
}

export default async function review(args) {
  const candidates = [
    ['code-review', args],
    ['bunx', ['code-review', ...args]],
    ['npx', ['--yes', 'code-review', ...args]],
  ]
  for (const [cmd, a] of candidates) {
    const r = await run(cmd, a)
    if (r.spawned) process.exit(r.code)
  }
  console.error('Could not find the `code-review` CLI. Install it (bun link code-review) or `npm i -g code-review`.')
  process.exit(127)
}
