# pipeline/src/component.coffee
#
# A helper for building component-model classes whose accessors are validated
# against the schema. Two ways to use it:
#
#   1. defineComponent(name, fields) — auto-generate a class with a camelCase
#      getter and a setPascalCase setter per field, each validated and
#      persisted. Good for simple components.
#
#   2. extend Component — write a hand-rolled class for compound/multi-field
#      methods, using `@check(subject, field)`, `@_load(id)`, `@_save(entity)`.
#
# Every accessor's FIRST argument is the calling subject's identity string,
# which must appear in the field's subjects[] allowlist in schema/*.yaml.
import { _G } from './globals.coffee'
import { SchemaValidator } from './schema-validator.coffee'
import './entity.coffee'

_camel  = (s) -> s.replace /_([a-z])/g, (_, c) -> c.toUpperCase()
_pascal = (s) -> (c = _camel s; c.charAt(0).toUpperCase() + c.slice 1)

export class Component
  # Subclasses set @COMPONENT_NAME = 'fetch'
  @check: (subject, field) -> SchemaValidator.check subject, @COMPONENT_NAME, field
  @_load: (activityId, id) -> _G.Entity.load activityId, id
  @_save: (activityId, entity) -> _G.Entity.save activityId, entity

# Build a validated component class from a flat list of scalar field names.
# Each field gets:  ComponentClass.<field>(subject, activityId, id)            → getter
#                   ComponentClass.set<Field>(subject, activityId, id, value)  → setter
# (For array components or multi-field writes, hand-roll a Component subclass.)
export defineComponent = (componentName, fieldNames = []) ->
  cls = class extends Component
  cls.COMPONENT_NAME = componentName

  for field in fieldNames
    do (field) ->
      getName = _camel field
      setName = 'set' + _pascal field
      cls[getName] = (subject, activityId, id) ->
        SchemaValidator.check subject, componentName, field
        entity = await _G.Entity.load activityId, id
        entity?[componentName]?[field] ? null
      cls[setName] = (subject, activityId, id, value) ->
        SchemaValidator.check subject, componentName, field
        entity = await _G.Entity.load activityId, id
        bag = entity[componentName] ? {}
        entity[componentName] = { ...bag, [field]: value }
        await _G.Entity.save activityId, entity
        value
  cls

export default Component
