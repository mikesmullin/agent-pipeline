# pipeline/src/world.coffee
#
# The in-memory entity cache + query index, **scoped per activity**. The disk is
# authoritative; World is a performance layer rebuilt from disk on startup and
# kept in sync by the chokidar watcher in entity.coffee.
#
# A project may host one activity or many. Call `_G.World.for(activityId)` to get
# a handle to that activity's cache; use the returned object's methods the same
# way a single global World worked. Single-activity projects use the synthesized
# `'default'` activity (see activities.coffee), so they never see the scoping.
#
# Systems PULL the entities they care about via `Entity.query(activityId, pred)`
# (archetype-style: select by which components are present) — they are never
# handed entities directly.
import { _G } from './globals.coffee'

# activityId → per-activity store handle
_worlds = {}

_makeWorld = ->
  store = {}
  array = []
  # Ids deleted from disk mid-run. A reference may still be held by an in-flight
  # system, which would re-save and resurrect the file. We block saves for
  # tombstoned ids until a real file with that id reappears on disk.
  tombstones = new Set()

  # O(1) lookup by id.
  get: (id) -> store[String id]

  set: (entity) ->
    id = String entity.id
    unless store[id]
      array.push entity
    else
      idx = array.findIndex (e) -> String(e.id) is id
      if idx >= 0 then array[idx] = entity else array.push entity
    store[id] = entity
    entity

  remove: (id) ->
    id = String id
    if store[id]
      delete store[id]
      filtered = array.filter (e) -> String(e.id) isnt id
      array.length = 0
      array.push filtered...

  tombstone:    (id) -> tombstones.add String(id)
  untombstone:  (id) -> tombstones.delete String(id)
  isTombstoned: (id) -> tombstones.has String(id)

  # The core query primitive: entities matching the predicate fn. O(n).
  Entity__find: (filterFn) -> array.filter filterFn
  # Alias used by systems/readers that want everything.
  find: (filterFn) -> array.filter filterFn
  all:  -> [...array]
  count: -> array.length
  size:  -> array.length

_G.World =
  # Get (lazily create) the cache handle for one activity.
  for: (activityId) ->
    key = String(activityId ? 'default')
    _worlds[key] ?= _makeWorld()
    _worlds[key]

  # Convenience: list activity ids that currently have a World.
  activityIds: -> Object.keys _worlds

export default _G.World
