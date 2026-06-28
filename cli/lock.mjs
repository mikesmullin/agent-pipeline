// cli/lock.mjs — a single-process lock for the cwd.
//
// `pipeline run` and `pipeline walk` both drive the same project (its db/, its
// agent.pid, its scratchpad space). Running two at once corrupts entity state
// and races the browser/session pools, so they share ONE lock file in the
// directory `pipeline` was invoked from: `.pipeline.lock`.
//
// The lock records the holder's pid + command + start time. A second invocation
// refuses to start while that pid is alive; a STALE lock (the holder died, e.g.
// kill -9 or a crash) is detected via `process.kill(pid, 0)` and reclaimed
// automatically. Pass `--force` / `--no-lock` to bypass (e.g. to `pipeline walk`
// a single entity WHILE the long-running loop holds the lock).

import { resolve } from 'path'
import { readFileSync, writeFileSync, unlinkSync, existsSync } from 'fs'

const LOCK_PATH = () => resolve(process.cwd(), '.pipeline.lock')

// Bypass flags (stripped from argv by stripLockFlags before passthrough).
const BYPASS = ['--force', '--no-lock']
export const wantsBypass = (args) => args.some((a) => BYPASS.includes(a))
export const stripLockFlags = (args) => args.filter((a) => !BYPASS.includes(a))

// Is `pid` a live process we should yield to? EPERM means it exists but isn't
// ours — still alive. ESRCH (thrown → caught → false) means it's gone.
const isAlive = (pid) => {
  if (!pid || pid === process.pid) return false
  try { process.kill(pid, 0); return true }
  catch (e) { return e.code === 'EPERM' }
}

// Acquire the cwd lock for `label` ('run' | 'walk'). Exits(1) when a live
// pipeline process already holds it; reclaims a stale lock. Wires cleanup so the
// lock is removed when this process exits. Returns release() (idempotent).
export function acquireLock(label, { bypass = false } = {}) {
  const path = LOCK_PATH()
  if (bypass) return () => {}

  if (existsSync(path)) {
    let info = {}
    try { info = JSON.parse(readFileSync(path, 'utf8')) } catch { info = {} }
    if (isAlive(info.pid)) {
      process.stderr.write(
        `pipeline ${label}: another pipeline process is already running in this directory ` +
        `(${info.cmd || 'pipeline'} · pid ${info.pid} · since ${info.startedAt || '?'}).\n`,
      )
      process.stderr.write(`Wait for it to finish, pass --force to override, or delete ${path} if it is stale.\n`)
      process.exit(1)
    }
    // Holder is dead → reclaim the stale lock.
    try { unlinkSync(path) } catch {}
    process.stderr.write(`pipeline ${label}: reclaimed a stale lock (pid ${info.pid || '?'} is gone).\n`)
  }

  writeFileSync(path, JSON.stringify({ pid: process.pid, cmd: `pipeline ${label}`, startedAt: new Date().toISOString() }, null, 2))

  let released = false
  const release = () => {
    if (released) return
    released = true
    try {
      // Only remove the file if it's still OURS (don't clobber a successor).
      const info = JSON.parse(readFileSync(path, 'utf8'))
      if (info.pid === process.pid) unlinkSync(path)
    } catch {}
  }
  // Sync cleanup on any normal/process.exit() termination.
  process.on('exit', release)
  return release
}

// Keep the CLI parent alive on Ctrl+C so the spawned child (agent.coffee) can
// run its OWN graceful shutdown — but be the idle SAFETY NET that force-kills a
// WEDGED child instead of needing `kill -9`.
//
// The child shares this process group (spawn without `detached`), so the tty
// delivers SIGINT to the child DIRECTLY on every Ctrl-C; the child's own handler
// does 1st press → graceful drain, 2nd press → force-exit. We therefore do NOT
// forward SIGINT (that would double-count and skip the child's graceful drain).
// The parent's loop is idle (it only waits on the child), so ITS signal handler
// always runs even when the child's event loop is saturated — so on the 3rd
// press we SIGKILL the child and exit, guaranteeing teardown. The lock is freed
// by the parent's process 'exit' handler in acquireLock.
export function forwardSignals(child) {
  let ints = 0
  process.on('SIGINT', () => {
    ints += 1
    if (ints === 1) process.stderr.write('\nShutting down — child is draining in-flight work. Press Ctrl-C twice more to force-kill.\n')
    if (ints >= 3) {
      process.stderr.write('Force quit (SIGKILL).\n')
      try { child.kill('SIGKILL') } catch {}
      process.exit(1)
    }
  })
  process.on('SIGTERM', () => { try { child.kill('SIGTERM') } catch {} })
}
