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
import { readFile, writeFile, mkdir, readdir, stat, rename } from 'fs/promises'
import { resolve, basename } from 'path'
import { load as yamlLoad, dump as yamlDump } from 'js-yaml'
import { createHash } from 'crypto'
import { AsyncLocalStorage } from 'async_hooks'
import chokidar from 'chokidar'
import { _G } from './globals.coffee'
import './world.coffee'
import { Activities } from './activities.coffee'
import { normalizeStrings } from './normalize.coffee'
import { pMap } from './pmap.coffee'

# Resolve an activity's entity dir + a single entity's file path. Single-activity
# projects use the synthesized 'default' activity (entityDir = _G.DB_DIR).
_dirOf  = (activityId) -> Activities.entityDir activityId
_fileOf = (activityId, id) ->
  if typeof id is 'object' or "#{id}" is '[object Object]'
    throw new Error "Entity id must be a scalar, got #{typeof id} for activity=#{activityId} (a system likely passed the entity object to transition/load instead of its id)"
  resolve _dirOf(activityId), "#{id}.yaml"

# ── Optimistic-concurrency (CAS) primitives ──────────────────────────────────
# A cheap per-file fingerprint (mtimeMs + size) captured on every read and checked
# on every write. `NEW` = sentinel for "the file does not exist yet".
_NEW = 'NEW'
_fpFromStat = (st) -> "#{st.mtimeMs}:#{st.size}"
_currentFp = (filePath) ->
  try _fpFromStat await stat filePath
  catch then _NEW
_MAX_CAS_RETRIES = 5
_sleep = (ms) -> new Promise (r) -> setTimeout r, ms

# Framework bookkeeping keys that never persist to disk.
_BOOKKEEPING = ['_mtime', '_fp', '_path', '_txn', '_full', '_projected', '_exists']
# Plain top-level data fields of an entity (drops bookkeeping). Shallow.
_dataOnly = (entity) ->
  out = {}
  out[k] = v for own k, v of (entity ? {}) when k not in _BOOKKEEPING
  out
# Replace `target`'s own keys IN PLACE with `source`'s, so a caller's entity
# reference stays valid across begin()/rollback().
_resetTo = (target, source) ->
  delete target[k] for own k of target
  Object.assign target, (source ? {})
  target

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
# safe — they never see a truncated projection. Scanning is tracked per-async-
# context (AsyncLocalStorage), NOT a global flag, so when stages run as concurrent
# workers, one stage's in-progress selection scan can never make ANOTHER stage's
# `processOne` read resolve to a projection — only the scanning async chain itself
# sees the flag. `_scanCtx` stores the activityId currently being scanned by this
# async context.
_scanCtx = new AsyncLocalStorage()   # store: { activityId } while inside that activity's query scan
_isScanning = (activityId) -> _scanCtx.getStore()?.activityId is activityId

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
  out._fp     = entity._fp    if entity._fp?
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
    # Skip a reload when the on-disk fingerprint already matches what's resident —
    # i.e. THIS is our OWN write (the writer updated World's `_fp` in _atomicWrite)
    # or the file is already current. This kills the self-write re-parse storm:
    # under the worker-pool model every component write fired a chokidar `change`
    # that re-parsed the whole (multi-MB) body, saturating the event loop. A
    # GENUINE external edit changes mtime/size → fingerprint differs → reload as
    # normal (so concurrent external editors are still picked up — the cheap `stat`
    # is the guard, not a parse).
    isOurOwnWrite = (id, p) =>
      resident = W().get String(id)
      return false unless resident?._fp?
      try (_fpFromStat await stat p) is resident._fp
      catch then false
    watcher = chokidar.watch dir,
      ignoreInitial: true
      depth: 0
      awaitWriteFinish: { stabilityThreshold: 200, pollInterval: 50 }
    watcher.on 'change', (p) =>
      return unless p.endsWith '.yaml'
      id = basename p, '.yaml'
      return if await isOurOwnWrite id, p
      await @_loadFromDisk activityId, id, p
    watcher.on 'add', (p) =>
      return unless p.endsWith '.yaml'
      id = basename p, '.yaml'
      W().untombstone id
      return if await isOurOwnWrite id, p
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
      st = await stat filePath
      entity = yamlLoad(await readFile filePath, 'utf8') ? { id }
      entity._mtime = st.mtimeMs
      entity._fp    = _fpFromStat st
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
    if _isScanning(activityId) and _indexFieldsFor(activityId)?
      return _G.World.for(activityId).get(String id) ? { id: String id }
    await @loadFull activityId, id

  # Re-read all of an activity's entities from disk (re-projecting in index mode
  # so it stays memory-safe; the chokidar watcher already covers operator edits).
  @reload: (activityId) ->
    for e in _G.World.for(activityId).all()
      await @_loadFromDisk activityId, e.id, (e._path ? _fileOf(activityId, e.id))

  # Persist the whole entity to <entityDir>/<id>.yaml (never moves). NON-CAS:
  # callers that need conflict detection go through @commit. Delegates to the
  # atomic writer so a crash can never leave a truncated YAML.
  @save: (activityId, entity) ->
    W = _G.World.for activityId
    if W.isTombstoned entity.id
      W.remove entity.id
      return entity
    await @_atomicWrite activityId, entity

  # Serialize + write the entity atomically (temp file + `rename` in the same dir).
  # Strips internal bookkeeping, normalizes strings to LF, restamps _mtime/_fp,
  # and refreshes the World cache. No fingerprint check — @commit does the CAS.
  @_atomicWrite: (activityId, entity) ->
    { _mtime, _fp, _path, _txn, _full, _projected, _exists, toWrite... } = entity
    normalized = normalizeStrings toWrite
    filePath = _fileOf activityId, entity.id
    await mkdir _dirOf(activityId), { recursive: true }
    tmp = "#{filePath}.tmp.#{process.pid}.#{Math.random().toString(36).slice 2, 8}"
    await writeFile tmp, yamlDump(normalized, { indent: 2, lineWidth: -1, noRefs: true }), 'utf8'
    await rename tmp, filePath
    try
      st = await stat filePath
      saved = { ...normalized, _mtime: st.mtimeMs, _fp: _fpFromStat(st), _path: filePath, _full: true }
    catch
      saved = { ...normalized, _path: filePath, _full: true }
    _G.World.for(activityId).set saved
    saved

  # ── Optimistic transactions (Golang style: entity is the first data arg) ─────
  # BEGIN — snapshot `entity` fresh from disk, capture its fingerprint + a shallow
  # base (for rollback), and mark it in-txn. Mutates `entity` IN PLACE to the
  # fresh body and returns it. A missing file → fingerprint NEW (so a create is
  # just a txn that commits a body where none existed).
  @begin: (activityId, entity) ->
    fresh = await @loadFull activityId, entity.id
    snap  = _dataOnly fresh
    fp    = fresh._fp ? _NEW
    _resetTo entity, snap
    entity._fp  = fp
    entity._txn = { fp, base: { ...snap }, open: true, dirty: new Set() }
    entity

  # COMMIT — CAS write. If the on-disk fingerprint still equals the begin()
  # snapshot, write atomically and close the txn → { ok:true }. If it changed
  # underneath us, write NOTHING → { ok:false, conflict:true }. Never auto-retries
  # (the @mutate wrapper does). A tombstoned id commits to a removal.
  @commit: (activityId, entity) ->
    txn = entity._txn
    throw new Error "Entity.commit('#{entity.id}') without an open begin()" unless txn?.open
    W = _G.World.for activityId
    if W.isTombstoned entity.id
      W.remove entity.id
      entity._txn = null
      return { ok: true, tombstoned: true }
    current = await _currentFp _fileOf(activityId, entity.id)
    unless current is txn.fp
      return { ok: false, conflict: true, expected: txn.fp, actual: current }
    saved = await @_atomicWrite activityId, entity
    entity._fp  = saved._fp
    entity._txn = null
    { ok: true }

  # ROLLBACK — discard in-memory edits back to the begin() snapshot; close the txn.
  @rollback: (activityId, entity) ->
    base = entity._txn?.base
    _resetTo entity, base if base?
    entity._txn = null
    entity

  # MUTATE — the convenience wrapper: begin → fn(entity) → commit, auto-retrying
  # on a CAS conflict (bounded, jittered). `id`-first. Returns the committed
  # entity; throws on exhausted retries (no data written → nothing corrupted).
  @mutate: (activityId, id, fn) ->
    for attempt in [1.._MAX_CAS_RETRIES]
      entity = { id: String id }
      await @begin activityId, entity
      await fn entity
      res = await @commit activityId, entity
      return entity if res.ok
      await _sleep (10 + Math.floor(Math.random() * 40))
    throw new Error "Entity.mutate('#{id}'): write conflict after #{_MAX_CAS_RETRIES} retries"

  # Optional dirty-tracking helpers (entity-first). They record touched dot-paths
  # on the open txn so a FUTURE field-level merge-on-conflict is possible; today
  # @commit still writes the whole body, so direct `entity.x = …` is equivalent.
  @setField: (activityId, entity, dotPath, value) ->
    parts = dotPath.split '.'
    obj = entity
    for part, i in parts
      if i is parts.length - 1
        obj[part] = value
      else
        obj[part] = obj[part] ? {}
        obj = obj[part]
    entity._txn?.dirty?.add dotPath
    entity

  @mergeComponent: (activityId, entity, component, partial) ->
    entity[component] = { ...(entity[component] or {}), ...partial }
    entity._txn?.dirty?.add "#{component}.#{k}" for k of partial
    entity

  @dirtyPaths: (entity) -> [...(entity._txn?.dirty ? new Set())]


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

  # Per-entity GC — re-project ONE hydrated body back to a thin projection. The
  # worker-pool model has no stage boundary, so each stage worker calls this after
  # it finishes one entity (instead of the whole-activity `evictHydrated`), keeping
  # at most `width × stageCount` full bodies resident. No-op when unindexed.
  @evictHydratedOne: (activityId, id) ->
    indexFields = _indexFieldsFor activityId
    return unless indexFields?
    W = _G.World.for activityId
    e = W.get String(id)
    W.set _project(e, indexFields) if e?._full
    list = _G._hydratedThisStage?[activityId]
    if Array.isArray list
      idx = list.indexOf String(id)
      list.splice idx, 1 if idx >= 0
    undefined

  # ── Mutation API (id-first, CAS-safe via @mutate) ──────────────────────────

  # Replace one top-level component (key) on the entity.
  @patch: (activityId, id, componentName, data) ->
    await @mutate activityId, id, (e) -> e[componentName] = data

  # Shallow-merge a partial update into an existing component.
  @merge: (activityId, id, componentName, partial) ->
    await @mutate activityId, id, (e) ->
      e[componentName] = { ...(e[componentName] or {}), ...partial }

  # Append an item to an array component.
  @append: (activityId, id, componentName, item) ->
    await @mutate activityId, id, (e) ->
      e[componentName] = [...(e[componentName] or []), item]

  # Set a nested value by dot path, e.g. 'workflow._stage'.
  @setPath: (activityId, id, dotPath, value) ->
    await @mutate activityId, id, (e) ->
      parts = dotPath.split '.'
      obj = e
      for part, i in parts
        if i is parts.length - 1
          obj[part] = value
        else
          obj[part] = obj[part] ? {}
          obj = obj[part]

  # Remove a set of top-level component keys (or dot-paths). The re-queue /
  # stage-rewind mechanism: strip a stage's outputs and the archetype-presence
  # query re-picks the entity up at the earliest missing stage on the next tick.
  @drop: (activityId, id, keys) ->
    await @mutate activityId, id, (e) ->
      for key in keys
        if key.includes '.'
          parts = key.split '.'
          obj = e
          for part, i in parts
            if i is parts.length - 1
              delete obj[part] if obj?
            else
              obj = obj?[part]
              break unless obj?
        else
          delete e[key]

  # Transition to a new stage (updates workflow._stage/_status/_updated_at).
  @transition: (activityId, id, newStage, extra = {}) ->
    fromStage = null
    saved = await @mutate activityId, id, (e) ->
      fromStage = e.workflow?._stage or 'none'
      e.workflow = {
        ...(e.workflow or {})
        _stage: newStage
        _status: extra._status or 'in_progress'
        _updated_at: new Date().toISOString()
        ...extra
      }
    _G.currentEntityId = String id
    _G.log "transition  #{fromStage} → #{newStage}"
    saved

  # Record an error and increment the retry counter (drives backoff).
  @recordError: (activityId, id, err) ->
    retryCount = 0
    await @mutate activityId, id, (e) ->
      now = new Date().toISOString()
      retryCount = (e.workflow?._retry_count or 0) + 1
      e.workflow = {
        ...(e.workflow or {})
        _last_error_at: now
        _retry_count: retryCount
        _last_error_message: String(err?.message or err)
        _updated_at: now
      }
    _G.log 'entity.error', { id: String(id), error: String(err?.message or err), retryCount }


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
    # `exclude` (Set or array of ids) skips entities a concurrent stage worker is
    # already processing — so the worker never re-claims an in-flight entity.
    # `order` orders the pool before scanning ('mtime' = oldest-eligible first for
    # fairness; default = World order).
    excl = opts.exclude
    isExcluded =
      if excl instanceof Set then ((id) -> excl.has String id)
      else if Array.isArray excl then (do -> s = new Set(excl.map String); (id) -> s.has id)
      else (-> false)
    indexFields = _indexFieldsFor activityId
    matched = []
    pool = _G.World.for(activityId).all()
    if _G.onlyEntity?
      pool = pool.filter (e) -> String(e.id) is String(_G.onlyEntity)
    if opts.order is 'mtime'
      pool = pool.slice().sort (a, b) -> (a._mtime ? 0) - (b._mtime ? 0)
    # Scan inside an AsyncLocalStorage context so `load` resolves to the cheap
    # projection for THIS scan only — a concurrent stage's processOne (a different
    # async chain) still reads full bodies.
    await _scanCtx.run { activityId }, =>
      for entity in pool
        continue if isExcluded entity.id
        _G.currentEntityId = entity.id
        result = await predicate entity
        continue if result is false
        matched.push entity
        break if matched.length >= limit
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

  # Create a new entity with just an id. CAS-guarded: a NO-OP when a file already
  # exists on disk (returns the existing full body) so a re-`create` can NEVER
  # clobber a fully-processed entity back to an empty stub — the lost-update
  # rewind we are guarding against. Only writes the stub when the file is absent.
  @create: (activityId, id) ->
    p = _fileOf activityId, id
    current = await _currentFp p
    return await @loadFull activityId, id unless current is _NEW   # already exists → no-op
    entity = { id: String id }
    await @begin activityId, entity                                # fp = NEW (no file yet)
    res = await @commit activityId, entity
    return entity if res.ok
    # Lost the create race (peer created it first) → return the peer's body.
    await @loadFull activityId, id

  # Git-style short id: 7-char truncated SHA1. Pass a seed for deterministic ids.
  @generateId: (seed = "#{Date.now()}-#{Math.random()}") ->
    createHash('sha1').update(String seed).digest('hex').slice 0, 7

export { Entity }
export default Entity
