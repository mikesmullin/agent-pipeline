# pipeline/src/world.coffee
#
# The in-memory entity cache + query index. The disk is authoritative; World is
# a performance layer rebuilt from disk on startup and kept in sync by the
# chokidar watcher in entity.coffee.
#
# Systems PULL the entities they care about via `World.Entity__find(predicate)`
# (archetype-style: select by which components are present) — they are never
# handed entities directly.
import { _G } from './globals.coffee'

_entities = {}
_entitiesArray = []
# Ids deleted from disk mid-run. A reference may still be held by an in-flight
# system, which would re-save and resurrect the file. We block saves for
# tombstoned ids until a real file with that id reappears on disk.
_tombstones = new Set()

_G.World =
  get: (id) -> _entities[String(id)]

  set: (entity) ->
    id = String entity.id
    unless _entities[id]
      _entitiesArray.push entity
    else
      idx = _entitiesArray.findIndex (e) -> String(e.id) is id
      if idx >= 0 then _entitiesArray[idx] = entity else _entitiesArray.push entity
    _entities[id] = entity
    entity

  remove: (id) ->
    id = String id
    if _entities[id]
      delete _entities[id]
      _entitiesArray = _entitiesArray.filter (e) -> String(e.id) isnt id

  tombstone:    (id) -> _tombstones.add String(id)
  untombstone:  (id) -> _tombstones.delete String(id)
  isTombstoned: (id) -> _tombstones.has String(id)

  # The core query primitive. Returns entities matching the predicate fn.
  Entity__find: (filterFn) -> _entitiesArray.filter filterFn

  # Alias for readability in systems that want all entities.
  all: -> [..._entitiesArray]

  count: -> _entitiesArray.length

export default _G.World
