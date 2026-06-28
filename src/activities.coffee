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

# Discover ACTIVITY-FIRST projects: each top-level dir holding an `activity.yaml`
# is one activity (its dir name is the on-disk grouping; the manifest's `id:` is
# still the canonical id). `shared/` and dot-dirs are skipped (no activity.yaml
# anyway, but skipped cheaply). Returns [{ name, dir }].
_discoverActivityFirst = (root) ->
  out = []
  try
    entries = readdirSync root, { withFileTypes: true }
  catch
    return out
  for ent in entries when ent.isDirectory()
    name = ent.name
    continue if name.startsWith '.'
    continue if name is 'shared'
    out.push { name, dir: resolve(root, name) } if existsSync resolve(root, name, 'activity.yaml')
  out

# Build one loaded-activity object from a parsed manifest + a layout context that
# tells it WHERE each referenced module lives (legacy central layout vs the
# activity-first per-dir layout). Shared by both branches of loadAll so the two
# layouts behave identically once resolved. `ctx`:
#   systemModulePath(moduleName) -> abs path to a system module
#   microagentModulePath(name)   -> abs path to a microagent module
#   resolveAgent(entry)          -> { name, abs } for an agent (string or {name,path})
#   entityDirBase                -> base dir for the (default or manifest) entityDir
#   defaultEntityDir             -> entityDir relative to base when manifest omits it
#   schemaFile / configFile / docsDir -> resolved abs paths (or null)
_buildActivity = (cfg, ctx) ->
  pipelineFns = []
  indexFields = new Set()       # union of every system's GATE_FIELDS (the activity index)
  anyDeclared = false
  for sysName in (cfg.pipeline ? [])
    moduleName = _systemNameToFile sysName
    modulePath = ctx.systemModulePath moduleName
    mod = await `import(pathToFileURL(modulePath).href)`
    fn = mod[sysName] ? mod.default
    unless typeof fn is 'function'
      throw new Error "activity #{cfg.id}: #{modulePath} does not export #{sysName}"
    # Worker-pool seams (STAGE_CONCURRENCY_PLAN): a system may ALSO export
    # `selectEligible(activityId,{exclude,limit})` + `processOne(activityId,id)`
    # so the framework can run it as a continuous per-entity worker (slots refill
    # as entities finish). `onTimeout(activityId,id)` marks an over-long entity
    # blocked; `cleanup()` runs once at loop shutdown (e.g. close a browser pool).
    # A system exporting ONLY the legacy `fn` still runs — the worker falls back
    # to looping `fn()` (batch-of-width) with idle backoff.
    pipelineFns.push {
      name: sysName, fn
      selectEligible: mod.selectEligible ? null
      processOne:     mod.processOne ? null
      onTimeout:      mod.onTimeout ? null
      cleanup:        mod.cleanup ? null
    }
    # GATE_FIELDS union → the World projection (field-index). See ARCHITECTURE #14.
    if Array.isArray mod.GATE_FIELDS
      anyDeclared = true
      indexFields.add f for f in mod.GATE_FIELDS
  # Microagents (legacy string form) — register-on-import side effect.
  for maName in (cfg.microagents ? [])
    await `import(pathToFileURL(ctx.microagentModulePath(maName)).href)`
  # Agents (superset): { name, path } or bare string shorthand.
  agentLabels = []
  for entry in (cfg.agents ? [])
    { name: agentName, abs } = ctx.resolveAgent entry
    await `import(pathToFileURL(abs).href)`
    agentLabels.push agentName
  {
    id:               cfg.id
    name:             cfg.name
    description:      cfg.description
    schemaFile:       ctx.schemaFile
    entityDir:        resolve ctx.entityDirBase, (cfg.entityDir ? ctx.defaultEntityDir)
    configFile:       ctx.configFile
    docsDir:          ctx.docsDir
    themeColor:       cfg.themeColor
    accentColor:      cfg.accentColor
    stages:           cfg.stages ? []
    pipeline:         pipelineFns
    # Field-index: union of pipeline systems' GATE_FIELDS, or null when none
    # declared (→ unindexed / full-body mode). Consumed by Entity in index mode.
    _indexFields:     (if anyDeclared then indexFields else null)
    microagents:      cfg.microagents ? []
    agents:           agentLabels
    jsonStringFields:        cfg.jsonStringFields ? []
    publishJsonStringFields: cfg.publishJsonStringFields ? []
    # Known optional/extension fields (consumers may use these in their UI).
    mascotDir:        cfg.mascotDir
    avatarName:       cfg.avatarName
    entityNoun:       cfg.entityNoun or 'entity'
  }

export class Activities
  @_registry = null

  # Load every activity manifest (or synthesize a default), resolve absolute
  # paths, and dynamically import each activity's systems + microagents + agents.
  # Idempotent: returns the cached registry on subsequent calls.
  #
  # DUAL-MODE — supports BOTH layouts:
  #   • LEGACY central:  activities/<id>.yaml + systems/<id>/ + microagents/<id>/
  #     + schema/<id>.yaml + db/entities/<id>/.
  #   • ACTIVITY-FIRST:  <activityDir>/activity.yaml + <activityDir>/{systems,
  #     microagents,agents}/ + <activityDir>/schema.yaml + <activityDir>/db/.
  # A project with neither is single-activity (synthesized `default`). The two
  # may coexist (e.g. during a migration); both are merged into one registry.
  @loadAll: ->
    return @_registry if @_registry?
    legacyDir   = resolve _G.ROOT, 'activities'
    hasLegacy   = existsSync legacyDir
    activityFirst = _discoverActivityFirst _G.ROOT
    unless hasLegacy or activityFirst.length > 0
      # Single-activity project: synthesize the default activity.
      @_registry = { "#{DEFAULT_ACTIVITY_ID}": _synthDefault() }
      return @_registry

    out = {}

    # ── Legacy central layout: activities/<id>.yaml ──────────────────────────
    if hasLegacy
      for file in readdirSync(legacyDir) when file.endsWith '.yaml'
        cfg = yamlLoad readFileSync(resolve(legacyDir, file), 'utf8')
        throw new Error "activity file #{file} missing `id`" unless cfg.id
        out[cfg.id] = await _buildActivity cfg,
          systemModulePath:     (moduleName) -> resolve _G.ROOT, "systems/#{cfg.id}/#{moduleName}.coffee"
          microagentModulePath: (name) -> resolve _G.ROOT, "microagents/#{cfg.id}/#{name}.coffee"
          resolveAgent: (entry) ->
            if typeof entry is 'string'
              { name: entry, abs: resolve(_G.ROOT, "agents/#{cfg.id}/#{entry}.coffee") }
            else
              { name: entry.name, abs: resolve(_G.ROOT, entry.path) }
          entityDirBase:    _G.ROOT
          defaultEntityDir: "db/entities/#{cfg.id}"
          schemaFile:       (if cfg.schemaFile then resolve(_G.ROOT, cfg.schemaFile) else null)
          configFile:       (if cfg.configFile then resolve(_G.ROOT, cfg.configFile) else null)
          docsDir:          (if cfg.docsDir then resolve(_G.ROOT, cfg.docsDir) else null)

    # ── Activity-first layout: <activityDir>/activity.yaml ───────────────────
    for { dir } in activityFirst
      cfg = yamlLoad readFileSync(resolve(dir, 'activity.yaml'), 'utf8')
      throw new Error "activity-first dir #{dir}: activity.yaml missing `id`" unless cfg.id
      out[cfg.id] = await _buildActivity cfg,
        systemModulePath:     (moduleName) -> resolve dir, "systems/#{moduleName}.coffee"
        microagentModulePath: (name) -> resolve dir, "microagents/#{name}.coffee"
        resolveAgent: (entry) ->
          if typeof entry is 'string'
            { name: entry, abs: resolve(dir, "agents/#{entry}.coffee") }
          else
            { name: entry.name, abs: resolve(dir, entry.path) }
        entityDirBase:    dir
        defaultEntityDir: 'db'
        schemaFile:       (if cfg.schemaFile then resolve(dir, cfg.schemaFile) else resolve(dir, 'schema.yaml'))
        configFile:       (if cfg.configFile then resolve(dir, cfg.configFile) else resolve(dir, 'config.yaml'))
        docsDir:          (if cfg.docsDir then resolve(dir, cfg.docsDir) else resolve(dir, 'docs'))

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
