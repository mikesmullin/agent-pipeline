# pipeline/src/entity.coffee
#
# The disk-authoritative persistence layer, **scoped per activity**. Entities
# live at <entityDir>/<id>.yaml (entityDir per activity; single-activity projects
# use the synthesized 'default' activity → flat db/). The stage lives INSIDE the
# YAML (workflow._stage or a status field), files never move, so editor tabs stay
# stable as work progresses.
#
# Every read goes through the model and loads from disk (mtime-guarded), so an
# operator editing a YAML in their editor takes effect on the next loop tick.
# The World cache is a performance layer only.
#
# `Entity` is a static "Golang-style" class: methods take `activityId` first,
# then the entity (or id); there is no per-entity object graph threaded through
# the loop. `Entity.query` owns the entity lifecycle (scan → hand full entities
# to the system fn → GC at fn exit), so systems carry no load/evict bookkeeping.
import { readFile, writeFile, mkdir, readdir, stat } from 'fs/promises'
import { resolve, basename } from 'path'
import { load as yamlLoad, dump as yamlDump } from 'js-yaml'
import { createHash } from 'crypto'
import chokidar from 'chokidar'
import { _G } from './globals.coffee'
import './world.coffee'
import { Activities } from './activities.coffee'
import { normalizeStrings } from './normalize.coffee'

# Resolve an activity's entity dir + a single entity's file path. Single-activity
# projects use the synthesized 'default' activity (entityDir = _G.DB_DIR).
_dirOf  = (activityId) -> Activities.entityDir activityId
_fileOf = (activityId, id) -> resolve _dirOf(activityId), "#{id}.yaml"

# One chokidar watcher per activity dir.
_watchers = {}   # activityId → FSWatcher

# ── Gate-field index (opt-in, low-memory selection) ──────────────────────────
# When `_G.useFieldIndex` is on AND an activity declares an index (the union of
# its systems' `GATE_FIELDS`, computed by Activities), the World holds only a thin
# PROJECTION of each entity (id + the gate-relevant component fields) instead of
# the full body — so 1015 large entities no longer balloon RSS to ~20GB.
#
# The full body is hydrated from disk ON DEMAND and is the DEFAULT a `load`
# returns — EXCEPT while a `query` predicate is scanning, where `load` returns the
# cheap resident projection (that is the whole point: gate predicates read only
# the indexed fields, fast, in memory). Because every NON-scan load returns a full
# body, all WRITE paths (component setters, fetch, server routes) are inherently
# safe — they never see a truncated projection. Scanning is tracked per-activity
# so parallel activities don't bleed each other's flag.
_scanning = {}   # activityId → bool (true only inside that activity's query scan)

_indexFieldsFor = (activityId) ->
  return null unless _G.useFieldIndex
  try
    Activities.get(activityId)?._indexFields ? null
  catch
    null

# Build a thin projection: id (+ _mtime/_path bookkeeping) + only the indexed
# `<component>.<field>` dot-paths that are actually present. NEVER carries the
# `_full` marker, so a projection is always distinguishable from a full body.
_project = (entity, indexFields) ->
  out = { id: String entity.id }
  out._mtime  = entity._mtime if entity._mtime?
  out._path   = entity._path  if entity._path?
  # Preserve existence semantics (Entity.exists = has >=1 revision) without
  # carrying the heavy revisions[] array into the projection.
  out._exists = ((entity?.revisions?.length ? 0) > 0)
  for dot from indexFields
    [comp, field] = dot.split '.'
    if field?
      val = entity?[comp]?[field]
      if val isnt undefined
        out[comp] ?= {}
        out[comp][field] = val
    else
      val = entity?[comp]
      out[comp] = val if val isnt undefined
  out

_G.Entity = class Entity
  # ── Persistence primitives ────────────────────────────────────────────────

  # Load all existing entity YAMLs for an activity from disk, then watch its dir
  # for operator edits. Called once per activity at startup.
  @init: (activityId = 'default') ->
    dir = _dirOf activityId
    await mkdir dir, { recursive: true }
    try
      for file in await readdir dir when file.endsWith '.yaml'
        await @_loadFromDisk activityId, basename(file, '.yaml'), resolve(dir, file)
    catch
    @_watch activityId, dir

  @_watch: (activityId, dir) ->
    return if _watchers[activityId]
    W = -> _G.World.for activityId
    watcher = chokidar.watch dir,
      ignoreInitial: true
      depth: 0
      awaitWriteFinish: { stabilityThreshold: 200, pollInterval: 50 }
    watcher.on 'change', (p) =>
      return unless p.endsWith '.yaml'
      await @_loadFromDisk activityId, basename(p, '.yaml'), p
    watcher.on 'add', (p) =>
      return unless p.endsWith '.yaml'
      id = basename p, '.yaml'
      W().untombstone id
      await @_loadFromDisk activityId, id, p
    watcher.on 'unlink', (p) =>
      return unless p.endsWith '.yaml'
      id = basename p, '.yaml'
      W().tombstone id   # block in-flight saves from resurrecting it
      W().remove id
    _watchers[activityId] = watcher

  # Stop all filesystem watchers (tests / graceful shutdown).
  @stopWatching: ->
    for activityId, watcher of _watchers
      await watcher.close()
      delete _watchers[activityId]

  @_loadFromDisk: (activityId, id, filePath, { full } = {}) ->
    try
      { mtimeMs } = await stat filePath
      entity = yamlLoad(await readFile filePath, 'utf8') ? { id }
      entity._mtime = mtimeMs
      entity._path  = filePath
    catch
      entity = { id: String(id) }
    entity.id = String(id)
    indexFields = _indexFieldsFor activityId
    if indexFields? and not full
      # Index mode: retain only a thin projection (the full body is GC'd).
      proj = _project entity, indexFields
      _G.World.for(activityId).set proj
      return proj
    entity._full = true
    _G.World.for(activityId).set entity
    entity

  # Always return the FULL entity body (reading disk if the resident copy is a
  # projection or stale). This is what every non-scan code path resolves to, so
  # mutations never operate on a truncated projection.
  @loadFull: (activityId, id) ->
    W = _G.World.for activityId
    cached = W.get String(id)
    if cached?._path and cached._full
      try
        { mtimeMs } = await stat cached._path
        return cached if cached._mtime is mtimeMs
      catch
    p = cached?._path ? _fileOf activityId, id
    try
      await stat p
      return await @_loadFromDisk activityId, id, p, { full: true }
    catch
    stub = { id: String(id) }
    W.set stub
    stub

  # Load by id. DEFAULT returns the full body (mtime-guarded). The ONE exception:
  # while this activity's `query` predicate is scanning AND the activity is in
  # index mode, return the resident projection (fast, no disk) — that is how gate
  # predicates read indexed fields cheaply. Returns a bare stub if no file exists.
  @load: (activityId, id) ->
    if _scanning[activityId] and _indexFieldsFor(activityId)?
      return _G.World.for(activityId).get(String id) ? { id: String id }
    await @loadFull activityId, id

  # Re-read all of an activity's entities from disk (re-projecting in index mode
  # so it stays memory-safe; the chokidar watcher already covers operator edits).
  @reload: (activityId) ->
    for e in _G.World.for(activityId).all()
      await @_loadFromDisk activityId, e.id, (e._path ? _fileOf(activityId, e.id))

  # Persist the whole entity to <entityDir>/<id>.yaml (never moves). Strips
  # internal bookkeeping (_mtime/_path) and normalizes strings to LF so
  # multi-line fields dump as readable YAML block scalars.
  @save: (activityId, entity) ->
    W = _G.World.for activityId
    if W.isTombstoned entity.id
      W.remove entity.id
      return entity
    { _mtime, _path, _full, _projected, _exists, toWrite... } = entity
    normalized = normalizeStrings toWrite
    filePath = _fileOf activityId, entity.id
    await mkdir _dirOf(activityId), { recursive: true }
    await writeFile filePath, yamlDump(normalized, { indent: 2, lineWidth: -1, noRefs: true }), 'utf8'
    # The saved object is a FULL body (writes always operate on full bodies);
    # mark it so evictHydrated re-projects it at the stage boundary.
    try
      { mtimeMs } = await stat filePath
      saved = { ...normalized, _mtime: mtimeMs, _path: filePath, _full: true }
    catch
      saved = { ...normalized, _path: filePath, _full: true }
    W.set saved
    saved

  # Evict one entity's body from the World cache to free memory. Streaming batch
  # runners use this to process the corpus one entity at a time instead of
  # bulk-loading all of them (which balloons RSS at large entity counts). Disk
  # stays authoritative; a later @load re-reads it.
  @evict: (activityId, id) ->
    _G.World.for(activityId).remove String id

  # Re-project every full body resident for this activity back to a thin
  # projection — the stage-boundary GC the loop calls after each system fn, so a
  # stage's full working set lives only for that fn (index mode only; no-op when
  # the activity has no index). This is what makes "the returned entity is GC'd
  # when the system fn exits" true: dropping World's reference to the full body
  # lets it be reclaimed. Disk stays authoritative.
  @evictHydrated: (activityId = 'default') ->
    indexFields = _indexFieldsFor activityId
    return unless indexFields?
    W = _G.World.for activityId
    for e in W.all() when e._full
      W.set _project(e, indexFields)
    _G._hydratedThisStage?[activityId] = []
    undefined

  # ── Mutation API (the entity object is the second arg) ─────────────────────

  # Replace one top-level component (key) on the entity.
  @patch: (activityId, entity, componentName, data) ->
    fresh = _G.World.for(activityId).get(entity.id) ? entity
    await @save activityId, { ...fresh, [componentName]: data }

  # Shallow-merge a partial update into an existing component.
  @merge: (activityId, entity, componentName, partial) ->
    fresh = _G.World.for(activityId).get(entity.id) ? entity
    existing = fresh[componentName] or {}
    await @save activityId, { ...fresh, [componentName]: { ...existing, ...partial } }

  # Append an item to an array component.
  @append: (activityId, entity, componentName, item) ->
    fresh = _G.World.for(activityId).get(entity.id) ? entity
    arr = fresh[componentName] or []
    await @save activityId, { ...fresh, [componentName]: [...arr, item] }

  # Set a nested value by dot path, e.g. 'workflow._stage'.
  @setPath: (activityId, entity, dotPath, value) ->
    fresh = _G.World.for(activityId).get(entity.id) ? entity
    parts = dotPath.split '.'
    updated = { ...fresh }
    obj = updated
    for part, i in parts
      if i is parts.length - 1
        obj[part] = value
      else
        obj[part] = { ...(obj[part] or {}) }
        obj = obj[part]
    await @save activityId, updated

  # Remove a set of top-level component keys (or dot-paths). The re-queue /
  # stage-rewind mechanism: strip a stage's outputs and the archetype-presence
  # query re-picks the entity up at the earliest missing stage on the next tick.
  @drop: (activityId, entity, keys) ->
    fresh = _G.World.for(activityId).get(entity.id) ? entity
    updated = { ...fresh }
    for key in keys
      if key.includes '.'
        parts = key.split '.'
        obj = updated
        for part, i in parts
          if i is parts.length - 1
            delete obj[part] if obj?
          else
            obj[part] = { ...(obj?[part] or {}) }
            obj = obj[part]
      else
        delete updated[key]
    await @save activityId, updated

  # Transition to a new stage (updates workflow._stage/_status/_updated_at).
  @transition: (activityId, entity, newStage, extra = {}) ->
    fresh = _G.World.for(activityId).get(entity.id) ? entity
    fromStage = fresh.workflow?._stage or 'none'
    now = new Date().toISOString()
    saved = await @save activityId, {
      ...fresh
      workflow: {
        ...(fresh.workflow or {})
        _stage: newStage
        _status: extra._status or 'in_progress'
        _updated_at: now
        ...extra
      }
    }
    _G.currentEntityId = entity.id
    _G.log "transition  #{fromStage} → #{newStage}"
    saved

  # Record an error and increment the retry counter (drives backoff).
  @recordError: (activityId, entity, err) ->
    fresh = _G.World.for(activityId).get(entity.id) ? entity
    now = new Date().toISOString()
    retryCount = (fresh.workflow?._retry_count or 0) + 1
    _G.log 'entity.error', { id: entity.id, error: String(err?.message or err), retryCount }
    await @save activityId, {
      ...fresh
      workflow: {
        ...(fresh.workflow or {})
        _last_error_at: now
        _retry_count: retryCount
        _last_error_message: String(err?.message or err)
        _updated_at: now
      }
    }

  # True while the entity is inside its post-error backoff window.
  @inBackoff: (entity) ->
    return false unless entity.workflow?._last_error_at
    (Date.now() - new Date(entity.workflow._last_error_at).getTime()) < _G.retry.backoffMs

  # ── Selection + read helpers ───────────────────────────────────────────────

  # All entity ids currently in World for this activity (F4-harness scoped).
  @allIds: (activityId) ->
    ids = _G.World.for(activityId).all().map (e) -> String e.id
    if _G.onlyEntity?
      ids = ids.filter (id) -> id is String(_G.onlyEntity)
    ids

  # Query — the standard entity-selection seam for systems. Iterates this
  # activity's World, runs an async `predicate(entity)` (the system's GATE
  # logic), and RETURNS UP TO `pipelineWidth` MATCHING ENTITIES. The framework
  # owns the batch cap (a cross-cutting default, NOT system gate logic) AND the
  # entity lifecycle/I-O: it scans the cache and hands the system fn full entity
  # objects scoped to that fn's lifetime, so systems carry no load/evict
  # bookkeeping.
  #
  # Match convention: a predicate matches UNLESS it explicitly returns `false`
  # (strict `=== false`). Any other return (true / undefined / object) matches:
  #   Entity.query activityId, (e) ->
  #     return false unless Gate 'captured', e.workflow?._stage is 'captured'
  #     # falls through → matches
  #
  # `_G.currentEntityId` is set before each predicate call so Gate() trace
  # attribution works without the system managing it.
  #
  # In index mode the World holds projections; the predicate scans those cheaply
  # (the `_scanning` flag makes component getters resolve to the resident
  # projection), then matches are HYDRATED to full bodies before being returned —
  # so the system fn always receives complete entities. The hydrated set is GC'd
  # back to projections by `evictHydrated` at the stage boundary.
  @query: (activityId, predicate, opts = {}) ->
    limit = opts.limit ? _G.pipelineWidth
    indexFields = _indexFieldsFor activityId
    matched = []
    pool = _G.World.for(activityId).all()
    if _G.onlyEntity?
      pool = pool.filter (e) -> String(e.id) is String(_G.onlyEntity)
    _scanning[activityId] = true
    try
      for entity in pool
        _G.currentEntityId = entity.id
        result = await predicate entity
        continue if result is false
        matched.push entity
        break if matched.length >= limit
    finally
      _scanning[activityId] = false
    # Hand back full bodies. In index mode hydrate each match from disk and track
    # it for stage-boundary eviction; otherwise the resident object is already full.
    return matched unless indexFields?
    hydrated = (_G._hydratedThisStage ?= {})
    list = (hydrated[activityId] ?= [])
    out = []
    for m in matched
      full = await @loadFull activityId, m.id
      list.push String(m.id)
      out.push full
    out

  # Has the entity been materialized (at least one revision recorded)? Honors the
  # projection's `_exists` marker in index mode (the full revisions[] is not
  # resident there).
  @exists: (activityId, id) ->
    e = _G.World.for(activityId).get id
    return true if e?._exists is true
    (e?.revisions?.length ? 0) > 0

  # Read-only snapshot of one entity (or all) — for serialization to the wire.
  @snapshot:    (activityId, id) -> _G.World.for(activityId).get id
  @snapshotAll: (activityId)     -> _G.World.for(activityId).all()
  @count:       (activityId)     -> _G.World.for(activityId).count()

  # Create a new entity with just an id; writes an empty stub to disk.
  @create: (activityId, id) ->
    await @save activityId, { id: String id }

  # Git-style short id: 7-char truncated SHA1. Pass a seed for deterministic ids.
  @generateId: (seed = "#{Date.now()}-#{Math.random()}") ->
    createHash('sha1').update(String seed).digest('hex').slice 0, 7

export { Entity }
export default Entity
