// pipeline g <kind> <name> — scaffold one system, component, or microagent
// into the current project, wired to the conventions.

import { writeFile, mkdir, readdir } from 'fs/promises'
import { resolve } from 'path'
import { existsSync } from 'fs'
import { load as yamlLoad } from 'js-yaml'
import { readFile } from 'fs/promises'

const camel = (s) => s.replace(/[-_ ]([a-z0-9])/gi, (_, c) => c.toUpperCase())
const pascal = (s) => { const c = camel(s); return c.charAt(0).toUpperCase() + c.slice(1) }
const kebab = (s) => s.replace(/[^a-z0-9]+/gi, '-').toLowerCase()

async function detectEntity(root) {
  try {
    const f = (await readdir(resolve(root, 'schema'))).find(x => x.endsWith('.yaml'))
    if (f) {
      const data = yamlLoad(await readFile(resolve(root, 'schema', f), 'utf8')) ?? {}
      return data.entity ?? f.replace(/\.yaml$/, '')
    }
  } catch {}
  return kebab(root.split('/').pop())
}

export default async function generate(args) {
  const [kind, rawName] = args
  if (!kind || !rawName) { console.error('Usage: pipeline g <system|component|microagent> <name>'); process.exit(1) }
  const root = process.cwd()
  const entity = await detectEntity(root)
  const name = kebab(rawName)

  if (kind === 'system') {
    await mkdir(resolve(root, 'systems'), { recursive: true })
    const path = resolve(root, 'systems', `${name}.coffee`)
    if (existsSync(path)) { console.error(`exists: ${path}`); process.exit(1) }
    await writeFile(path, `# ${name} — selects the entities it cares about (archetype query) and advances them.
import { _G, Entity } from 'pipeline'

SYSTEM = 'system:${entity}/${name}'

export ${camel(name)}System = ->
  targets = _G.World.Entity__find (e) ->
    # TODO: select by component presence / stage, e.g.:
    # e.workflow?._stage is 'captured' and not e.${name}? and not Entity.inBackoff e
    false

  for entity in targets[0..._G.pipelineWidth]
    _G.currentEntityId = entity.id
    try
      # TODO: deterministic work + (optional) one microagent call; then persist.
      await Entity.transition entity, 'TODO_next_stage'
    catch err
      await Entity.recordError entity, err

export default ${camel(name)}System
`, 'utf8')
    console.log(`Created systems/${name}.coffee`)
    console.log(`Remember to add \`- name: ${name}\` to config.yaml's systems: list.`)

  } else if (kind === 'component') {
    await mkdir(resolve(root, 'models/components'), { recursive: true })
    const path = resolve(root, 'models/components', `${name}.coffee`)
    if (existsSync(path)) { console.error(`exists: ${path}`); process.exit(1) }
    await writeFile(path, `# ${pascal(name)}Component — validated accessors for entity.${name}.*
# Declare the matching component + fields (with subjects allowlists) in
# schema/${entity}.yaml, then list the field names here.
import { defineComponent } from 'pipeline'

export ${pascal(name)}Component = defineComponent '${name}', [
  # 'field_one'
  # 'field_two'
]
export default ${pascal(name)}Component
`, 'utf8')
    console.log(`Created models/components/${name}.coffee`)
    console.log(`Add a \`${name}:\` component block to schema/${entity}.yaml.`)

  } else if (kind === 'microagent') {
    await mkdir(resolve(root, 'microagents'), { recursive: true })
    // Number prefix based on existing count.
    let count = 0
    try { count = (await readdir(resolve(root, 'microagents'))).filter(f => f.endsWith('.coffee')).length } catch {}
    const prefix = String(count + 1).padStart(2, '0')
    const path = resolve(root, 'microagents', `${prefix}-${name}.coffee`)
    if (existsSync(path)) { console.error(`exists: ${path}`); process.exit(1) }
    await writeFile(path, `# ${name} — one subjective decision. Minimal system prompt; field semantics
# live in the output schema, NOT the prompt. Deterministic work stays outside.
import { Agent, _G } from 'pipeline'

# SUBJECT = 'microagent:${entity}/${name}'   # if it accesses components

_G.${camel(name)}Microagent = (input) ->
  _G.traceStep '🔍', "${name}", ->
    microagent = await Agent.factory
      system_prompt: """
      One sentence of decision intent + constraints + quality bar. Nothing else.
      """
      output_tool:
        name: '${camel(name)}_result'
        description: 'The structured decision.'
        parameters:
          # Put detailed field semantics in these descriptions.
          result:
            type: 'string'
            description: 'TODO'
    out = await microagent.run "<input>#{input}</input>"
    out.result

export default _G.${camel(name)}Microagent
`, 'utf8')
    console.log(`Created microagents/${prefix}-${name}.coffee`)

  } else {
    console.error(`Unknown kind: ${kind} (expected system|component|microagent)`)
    process.exit(1)
  }
}
