# pipeline/src/activities.coffee
#
# The activity registry. An **Activity** is one named pipeline (one entity kind)
# a project hosts. A project may host one activity or many; they run
# independently over their own entity dirs.
#
# Two modes, same API:
#   • MULTI-ACTIVITY — the project has an `activities/<id>.yaml` per activity.
#     `loadAll()` reads each manifest and dynamically imports its systems /
#     microagents / agents (each registers itself on _G as an import side
#     effect). Per-activity entity dirs: `db/entities/<id>/`.
#   • SINGLE-ACTIVITY — no `activities/` dir. We synthesize ONE `'default'`
#     activity whose entityDir is `_G.DB_DIR` (the flat `db/` layout). The
#     framework's config-driven loop imports its systems separately, so the
#     synthesized activity carries an empty pipeline — it exists only so the
#     entity layer can resolve a dir + a World scope by id.
#
# The activity-id comes from each manifest's top-level `id:` key (NOT the
# filename).
import { readdirSync, existsSync } from 'fs'
import { resolve } from 'path'
import { readFileSync } from 'fs'
import { pathToFileURL } from 'url'
import { load as yamlLoad } from 'js-yaml'
import { _G } from './globals.coffee'

DEFAULT_ACTIVITY_ID = 'default'

# Convert a system function name to its module filename (sans .coffee):
#   fetchSystem        -> 'fetch'
#   adminApproveSystem -> 'admin-approve'
_systemNameToFile = (name) ->
  base = name.replace /System$/, ''
  base.replace(/([A-Z])/g, (_m, c) -> '-' + c.toLowerCase()).replace(/^-/, '')

# The synthesized single-activity descriptor (lazy; used when no activities/).
_synthDefault = ->
  id:               DEFAULT_ACTIVITY_ID
  name:             DEFAULT_ACTIVITY_ID
  description:      null
  schemaFile:       null
  entityDir:        _G.DB_DIR
  configFile:       resolve _G.ROOT, 'config.yaml'
  docsDir:          resolve _G.ROOT, 'docs'
  stages:           []
  pipeline:         []
  microagents:      []
  agents:           []
  jsonStringFields: []
  synthesized:      true

export class Activities
  @_registry = null

  # Load every activities/*.yaml (or synthesize a default), resolve absolute
  # paths, and dynamically import each activity's systems + microagents + agents.
  # Idempotent: returns the cached registry on subsequent calls.
  @loadAll: ->
    return @_registry if @_registry?
    dir = resolve _G.ROOT, 'activities'
    unless existsSync dir
      # Single-activity project: synthesize the default activity.
      @_registry = { "#{DEFAULT_ACTIVITY_ID}": _synthDefault() }
      return @_registry

    out = {}
    for file in readdirSync(dir) when file.endsWith '.yaml'
      cfg = yamlLoad readFileSync(resolve(dir, file), 'utf8')
      throw new Error "activity file #{file} missing `id`" unless cfg.id
      pipelineFns = []
      indexFields = new Set()       # union of every system's GATE_FIELDS (the activity index)
      anyDeclared = false
      for sysName in (cfg.pipeline ? [])
        moduleName = _systemNameToFile sysName
        modulePath = resolve _G.ROOT, "systems/#{cfg.id}/#{moduleName}.coffee"
        mod = await `import(pathToFileURL(modulePath).href)`
        fn = mod[sysName] ? mod.default
        unless typeof fn is 'function'
          throw new Error "activity #{cfg.id}: systems/#{cfg.id}/#{moduleName}.coffee does not export #{sysName}"
        pipelineFns.push { name: sysName, fn }
        # GATE_FIELDS: the component dot-fields this system's gate predicate reads.
        # Their union across the pipeline is what the World projection must carry
        # (see the field-index feature). A system with no gate (e.g. a reporter)
        # may omit it; an activity where NO system declares any stays unindexed
        # (full-body mode), preserving back-compat.
        if Array.isArray mod.GATE_FIELDS
          anyDeclared = true
          indexFields.add f for f in mod.GATE_FIELDS
      # Microagents (legacy string form) — register-on-import side effect.
      for maName in (cfg.microagents ? [])
        await `import(pathToFileURL(resolve(_G.ROOT, "microagents/#{cfg.id}/#{maName}.coffee")).href)`
      # Agents (superset): { name, path } or bare string shorthand.
      agentLabels = []
      for entry in (cfg.agents ? [])
        { name: agentName, path: agentRelPath } =
          if typeof entry is 'string'
            { name: entry, path: "agents/#{cfg.id}/#{entry}.coffee" }
          else entry
        await `import(pathToFileURL(resolve(_G.ROOT, agentRelPath)).href)`
        agentLabels.push agentName
      out[cfg.id] =
        id:               cfg.id
        name:             cfg.name
        description:      cfg.description
        schemaFile:       if cfg.schemaFile then resolve(_G.ROOT, cfg.schemaFile) else null
        entityDir:        resolve _G.ROOT, (cfg.entityDir ? "db/entities/#{cfg.id}")
        configFile:       if cfg.configFile then resolve(_G.ROOT, cfg.configFile) else null
        docsDir:          if cfg.docsDir then resolve(_G.ROOT, cfg.docsDir) else null
        themeColor:       cfg.themeColor
        accentColor:      cfg.accentColor
        stages:           cfg.stages ? []
        pipeline:         pipelineFns
        # Field-index: the union of pipeline systems' GATE_FIELDS (a Set of
        # `<component>.<field>` dot-paths), or null when no system declares any
        # (→ unindexed / full-body mode). Consumed by Entity in index mode.
        _indexFields:     (if anyDeclared then indexFields else null)
        microagents:      cfg.microagents ? []
        agents:           agentLabels
        jsonStringFields:        cfg.jsonStringFields ? []
        publishJsonStringFields: cfg.publishJsonStringFields ? []
        # Known optional/extension fields (consumers may use these in their UI).
        mascotDir:        cfg.mascotDir
        avatarName:       cfg.avatarName
        entityNoun:       cfg.entityNoun or 'entity'
    @_registry = out
    out

  # Reset (tests / re-scan after editing manifests).
  @reset: -> @_registry = null

  # Return a single activity by id. Lazily synthesizes the default activity so
  # single-activity callers (and the entity layer) work before/without loadAll.
  @get: (id = DEFAULT_ACTIVITY_ID) ->
    if @_registry?
      a = @_registry[id]
      return a if a
      # Unknown id, but allow the synthesized default on demand.
      return (@_registry[DEFAULT_ACTIVITY_ID] ?= _synthDefault()) if id is DEFAULT_ACTIVITY_ID
      throw new Error "unknown activity '#{id}'"
    # Not loaded yet: only the default is resolvable.
    return _synthDefault() if id is DEFAULT_ACTIVITY_ID
    throw new Error "Activities.loadAll() must be called before requesting activity '#{id}'"

  # Resolve an activity's entity directory by id (the hot path for Entity).
  @entityDir: (id = DEFAULT_ACTIVITY_ID) -> @get(id).entityDir

  @all: ->
    throw new Error 'Activities.loadAll() must be called before Activities.all()' unless @_registry?
    Object.values @_registry

  @ids: ->
    throw new Error 'Activities.loadAll() must be called before Activities.ids()' unless @_registry?
    Object.keys @_registry

export default Activities
