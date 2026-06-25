# pipeline/src/gate.coffee
#
# Gate — a first-class, parsable marker around pipeline GATE LOGIC.
#
# Gate logic is the single most important thing for an agent to get right: it
# decides which entities a system picks up and when a system aborts processing
# an entity. When it's wrong, an entity gets "stuck" (never selected, or always
# skipped). To make that logic enforceable, debuggable, and self-documenting, we
# funnel it through ONE sanctioned wrapper — exactly as component access is
# funneled through the validated component models (the ACL).
#
# `Gate` is a pass-through marker. It returns the boolean it wraps, so it can be
# dropped around ANY gate predicate or guard, anywhere in a system, any number
# of times — no refactoring, no merging conditions. Two forms:
#
#   continue unless Gate 'status convertible', status in ['original','converted']
#   targets = World.Entity__find (e) -> Gate e.workflow?._stage is 'captured'
#
# Because every gate goes through this marker:
#   • `pipeline check`  can flag gate-ish logic that ISN'T wrapped (static).
#   • `pipeline docs`   can extract each gate's label + condition into a
#                       Gate Logic table (deterministic — no LLM).
#   • runtime           records pass/fail per current entity, so you can answer
#                       "why is entity X stuck?" by inspecting `_G.gateLog`.
import { _G } from './globals.coffee'

_GATE_LOG_MAX = 1000
_G.gateLog ?= []

# Gate(cond) | Gate(label, cond) → returns cond (pass-through marker).
export Gate = (labelOrCond, cond) ->
  if cond is undefined
    label = null
    value = labelOrCond
  else
    label = labelOrCond
    value = cond
  entry =
    system: _G.currentSystem ? null
    entity: _G.currentEntityId ? null
    label:  label
    passed: !!value
    at:     Date.now()
  _G.gateLog.push entry
  _G.gateLog.shift() while _G.gateLog.length > _GATE_LOG_MAX
  value

# Return the recent gate evaluations for one entity (most-recent first) — the
# "why is X stuck?" view. Each: { system, label, passed, at }.
export gateTrace = (entityId) ->
  id = String entityId
  _G.gateLog.filter((g) -> String(g.entity) is id).reverse()

_G.Gate = Gate
_G.gateTrace = gateTrace

export default Gate
