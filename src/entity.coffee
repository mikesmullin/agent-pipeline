# pipeline/src/entity.coffee
#
# The disk-authoritative persistence layer. Entities live flat at
# db/<id>.yaml — the stage lives INSIDE the YAML (workflow._stage), files never
# move, so editor tabs stay stable as work progresses.
#
# Every read goes through the model and loads from disk (mtime-guarded), so an
# operator editing a YAML in their editor takes effect on the next loop tick.
# The World cache is a performance layer only.
#
# `Entity` is a static "Golang-style" class: methods take the entity as the
# first argument; there is no per-entity object graph to thread through the loop.
import { readFile, writeFile, mkdir, readdir, stat } from 'fs/promises'
import { resolve, basename } from 'path'
import { load as yamlLoad, dump as yamlDump } from 'js-yaml'
import { createHash } from 'crypto'
import chokidar from 'chokidar'
import { _G } from './globals.coffee'
import './world.coffee'

_entityPath = (id) -> resolve _G.DB_DIR, "#{id}.yaml"

_G.Entity = class Entity
  # Load all existing entity YAMLs from disk, then watch db/ for operator edits.
  @init: ->
    await mkdir _G.DB_DIR, { recursive: true }
    try
      for file in await readdir _G.DB_DIR when file.endsWith '.yaml'
        id = basename file, '.yaml'
        await @_loadFromDisk id, resolve(_G.DB_DIR, file)
    catch

    _G._watcher = chokidar.watch _G.DB_DIR,
      ignoreInitial: true
      depth: 0
      awaitWriteFinish: { stabilityThreshold: 200, pollInterval: 50 }
    .on 'change', (p) =>
      return unless p.endsWith '.yaml'
      await @_loadFromDisk basename(p, '.yaml'), p
    .on 'add', (p) =>
      return unless p.endsWith '.yaml'
      id = basename p, '.yaml'
      _G.World.untombstone id
      await @_loadFromDisk id, p
    .on 'unlink', (p) =>
      return unless p.endsWith '.yaml'
      id = basename p, '.yaml'
      _G.World.tombstone id   # block in-flight saves from resurrecting it
      _G.World.remove id

  @_loadFromDisk: (id, filePath) ->
    try
      { mtimeMs } = await stat filePath
      entity = yamlLoad(await readFile filePath, 'utf8') ? { id }
      entity._mtime = mtimeMs
      entity._path  = filePath
    catch
      entity = { id: String(id) }
    entity.id = String(id)
    _G.World.set entity
    entity

  # Load by id. Returns the cached copy when its on-disk mtime is unchanged,
  # otherwise reloads from disk. Returns a bare stub if no file exists.
  @load: (id) ->
    cached = _G.World.get String(id)
    if cached?._path
      try
        { mtimeMs } = await stat cached._path
        return cached if cached._mtime is mtimeMs
        return await @_loadFromDisk id, cached._path
      catch
    p = _entityPath id
    try
      await stat p
      return await @_loadFromDisk id, p
    catch
    stub = { id: String(id) }
    _G.World.set stub
    stub

  # Persist the whole entity to db/<id>.yaml (never moves). Strips internal
  # bookkeeping (_mtime/_path) before dumping.
  @save: (entity) ->
    if _G.World.isTombstoned entity.id
      _G.World.remove entity.id
      return entity
    { _mtime, _path, toWrite... } = entity
    filePath = _entityPath entity.id
    await mkdir _G.DB_DIR, { recursive: true }
    await writeFile filePath, yamlDump(toWrite, { indent: 2, lineWidth: 120, noRefs: true }), 'utf8'
    try
      { mtimeMs } = await stat filePath
      saved = { ...toWrite, _mtime: mtimeMs, _path: filePath }
    catch
      saved = { ...toWrite, _path: filePath }
    _G.World.set saved
    saved

  # Replace one top-level component (key) on the entity.
  @patch: (entity, componentName, data) ->
    fresh = _G.World.get(entity.id) ? entity
    await @save { ...fresh, [componentName]: data }

  # Shallow-merge a partial update into an existing component.
  @merge: (entity, componentName, partial) ->
    fresh = _G.World.get(entity.id) ? entity
    existing = fresh[componentName] or {}
    await @save { ...fresh, [componentName]: { ...existing, ...partial } }

  # Append an item to an array component.
  @append: (entity, componentName, item) ->
    fresh = _G.World.get(entity.id) ? entity
    arr = fresh[componentName] or []
    await @save { ...fresh, [componentName]: [...arr, item] }

  # Set a nested value by dot path, e.g. 'workflow._stage'.
  @setPath: (entity, dotPath, value) ->
    fresh = _G.World.get(entity.id) ? entity
    parts = dotPath.split '.'
    updated = { ...fresh }
    obj = updated
    for part, i in parts
      if i is parts.length - 1
        obj[part] = value
      else
        obj[part] = { ...(obj[part] or {}) }
        obj = obj[part]
    await @save updated

  # Remove a set of top-level component keys (or dot-paths). This is the
  # re-queue / stage-rewind mechanism: strip a stage's outputs and the
  # archetype-presence query re-picks the entity up at the earliest missing
  # stage on the next tick.
  @drop: (entity, keys) ->
    fresh = _G.World.get(entity.id) ? entity
    updated = { ...fresh }
    for key in keys
      if key.includes '.'
        parts = key.split '.'
        obj = updated
        ok = true
        for part, i in parts
          if i is parts.length - 1
            delete obj[part] if obj?
          else
            obj[part] = { ...(obj?[part] or {}) }
            obj = obj[part]
            (ok = false) unless obj?
      else
        delete updated[key]
    await @save updated

  # Transition to a new stage (updates workflow._stage/_status/_updated_at).
  @transition: (entity, newStage, extra = {}) ->
    fresh = _G.World.get(entity.id) ? entity
    fromStage = fresh.workflow?._stage or 'none'
    now = new Date().toISOString()
    saved = await @save {
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
  @recordError: (entity, err) ->
    fresh = _G.World.get(entity.id) ? entity
    now = new Date().toISOString()
    retryCount = (fresh.workflow?._retry_count or 0) + 1
    _G.log 'entity.error', { id: entity.id, error: String(err?.message or err), retryCount }
    await @save {
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

  # Query — the standard entity-selection seam for systems. Iterates the World,
  # runs an async `predicate(entity)` (which expresses the system's GATE logic),
  # and returns up to `pipelineWidth` matches. The FRAMEWORK owns the batch cap
  # here (a cross-cutting default, NOT system gate logic) — so systems never
  # write the pipelineWidth break themselves.
  #
  # Match convention: a predicate matches UNLESS it explicitly returns `false`
  # (strict `=== false`). Any other return — `true`, `undefined` (no return),
  # an object, etc. — counts as a match. This lets a gate read naturally:
  #   Entity.query (e) ->
  #     return false unless Gate 'captured', e.workflow?._stage is 'captured'
  #     # falls through → matches
  #
  # `_G.currentEntityId` is set before each predicate call so Gate() trace
  # attribution works without the system managing it.
  @query: (predicate, opts = {}) ->
    limit = opts.limit ? _G.pipelineWidth
    out = []
    pool = _G.World.all()
    # F4 dev harness: scope selection to a single entity when _G.onlyEntity is set.
    if _G.onlyEntity?
      pool = pool.filter (e) -> String(e.id) is String(_G.onlyEntity)
    for entity in pool
      _G.currentEntityId = entity.id
      result = await predicate entity
      continue if result is false
      out.push entity
      break if out.length >= limit
    out

  # Git-style short id: 7-char truncated SHA1. Pass a seed for deterministic ids.
  @generateId: (seed = "#{Date.now()}-#{Math.random()}") ->
    createHash('sha1').update(String seed).digest('hex').slice 0, 7

export { Entity }
export default Entity
