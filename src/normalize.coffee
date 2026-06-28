# pipeline/src/normalize.coffee
#
# Recursively deep-clone a value, normalizing every string to LF line endings
# (not CRLF or lone CR). Applied at Entity.save time so multi-line string fields
# dump as readable YAML block scalars (js-yaml's literal `|` style is LF-only;
# a CRLF forces an escaped single-line quoted string — unreadable on disk).
# Cosmetic at the byte level, not behavioral.
export normalizeStrings = (v) ->
  if typeof v is 'string'
    v.replace(/\r\n/g, '\n').replace(/\r/g, '\n')
  else if Array.isArray v
    v.map normalizeStrings
  else if v? and typeof v is 'object'
    out = {}
    out[k] = normalizeStrings(x) for k, x of v
    out
  else
    v

export default normalizeStrings
