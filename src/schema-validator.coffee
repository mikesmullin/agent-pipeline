# pipeline/src/schema-validator.coffee
#
# Runtime access-control guard for component fields. Every component
# getter/setter calls `SchemaValidator.check(subject, component, field)` as its
# first line. The schema is read fresh from disk (_G.SCHEMA_DIR) on every call —
# no caching — so allowlist edits take effect immediately, no restart.
#
# Subjects (callers) carry a kind-prefix:
#   system:<activity>/<name>       e.g. system:beam-rule/fetch
#   microagent:<activity>/<name>   e.g. microagent:beam-rule/convert-rule
#   route:<activity>/:uid/<verb>   e.g. route:beam-rule/:uid/approve
#
# Violations are FATAL (process.exit 1, not a throw) and print the schema file
# path so any reader — human or agent — knows exactly where to fix the allowlist.
import { readFileSync, readdirSync, existsSync } from 'fs'
import { resolve } from 'path'
import { load as yamlLoad } from 'js-yaml'
import { _G } from './globals.coffee'

_fatal = (lines) ->
  process.stderr.write l + '\n' for l in lines
  process.exit 1

# Schema files, DUAL-MODE. Prefer the LEGACY central `schema/` dir; only when it
# holds no YAML fall back to the ACTIVITY-FIRST per-activity
# `<ROOT>/<activity>/schema.yaml`. Returns absolute paths. (Legacy-present
# projects keep their exact one-readdir hot path; only activity-first projects
# pay the root scan.)
_schemaFiles = ->
  legacy = []
  try
    legacy = (resolve(_G.SCHEMA_DIR, f) for f in readdirSync(_G.SCHEMA_DIR) when f.endsWith '.yaml')
  return legacy if legacy.length > 0
  out = []
  try
    for ent in readdirSync(_G.ROOT, { withFileTypes: true }) when ent.isDirectory() and not ent.name.startsWith('.')
      p = resolve _G.ROOT, ent.name, 'schema.yaml'
      out.push p if existsSync p
  out

export class SchemaValidator
  # Read all schema/*.yaml fresh. When a component is declared in multiple
  # files (shared component), field subjects[] allowlists are UNIONed; other
  # props are last-wins (alphabetical file order).
  @_loadAll: ->
    out = { components: {}, scalars: {} }
    for path in _schemaFiles()
      try
        data = yamlLoad readFileSync(path, 'utf8')
      catch
        continue
      continue unless data
      for compName, comp of (data.components or {})
        existing = out.components[compName]
        if existing
          merged = Object.assign {}, existing.fields
          for fname, fdef of (comp.fields or {})
            ef = merged[fname]
            if ef
              m = Object.assign {}, ef, fdef
              m.subjects = [...new Set([...(ef.subjects or []), ...(fdef.subjects or [])])]
              merged[fname] = m
            else
              merged[fname] = fdef
          out.components[compName] = { fields: merged, schemaFile: path, schemaFiles: [...existing.schemaFiles, path], array: comp.array ? existing.array, description: comp.description ? existing.description }
        else
          out.components[compName] = { fields: comp.fields or {}, schemaFile: path, schemaFiles: [path], array: comp.array or false, description: comp.description }
      for name, def of (data.scalars or {})
        existing = out.scalars[name]
        if existing
          m = Object.assign {}, existing.def, def
          m.subjects = [...new Set([...(existing.def.subjects or []), ...(def.subjects or [])])]
          out.scalars[name] = { def: m, schemaFile: path }
        else
          out.scalars[name] = { def, schemaFile: path }
    out

  # Validate (subject, component, field). Fatal on any violation.
  @check: (subject, componentName, fieldName) ->
    schemas = @_loadAll()
    comp = schemas.components[componentName]
    unless comp
      _fatal ["FATAL: unknown component '#{componentName}' (called by '#{subject}')", "  Schema dir: #{_G.SCHEMA_DIR}"]
    field = comp.fields[fieldName]
    unless field
      _fatal ["FATAL: unknown field '#{componentName}.#{fieldName}' (called by '#{subject}')", "  Schema:  #{comp.schemaFile}"]
    allowed = field.subjects or []
    return if allowed.includes subject
    _fatal [
      "FATAL: '#{subject}' is not authorized to access #{componentName}.#{fieldName}"
      "  Allowed: #{allowed.join ', '}"
      "  Schema:  #{comp.schemaFile}"
    ]

  # Validate a top-level scalar (e.g. 'id'). Same semantics as check().
  @checkScalar: (subject, scalarName) ->
    schemas = @_loadAll()
    s = schemas.scalars[scalarName]
    unless s
      _fatal ["FATAL: unknown scalar '#{scalarName}' (called by '#{subject}')", "  Schema dir: #{_G.SCHEMA_DIR}"]
    allowed = s.def.subjects or []
    return if allowed.includes subject
    _fatal [
      "FATAL: '#{subject}' is not authorized to access scalar '#{scalarName}'"
      "  Allowed: #{allowed.join ', '}"
      "  Schema:  #{s.schemaFile}"
    ]

export default SchemaValidator
