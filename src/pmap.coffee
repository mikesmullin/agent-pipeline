# pmap.coffee
#
# Bounded-concurrency async map — the primitive that lets a pipeline STAGE
# process its independent entities in parallel without unbounded fan-out.
#
# Each stage pulls N entities it may advance (the gate already proved they're
# independent), then runs `fn` over them with at most `concurrency` in flight at
# once (concurrency = pipeline_width). Errors are isolated per item — one bad
# entity never rejects the whole batch — and surfaced in the result array so the
# caller can log/count them, matching the "one bad entity never wedges the loop"
# contract.
#
#   results = await pMap items, width, (item, i) -> await doWork item
#   # results[i] = { ok: true, value }  |  { ok: false, error }

export pMap = (items, concurrency, fn) ->
  list = Array.from items ? []
  n = list.length
  results = new Array n
  return results if n is 0
  limit = Math.max 1, (concurrency ? 1)
  next = 0

  worker = ->
    loop
      i = next++
      break if i >= n
      try
        value = await fn list[i], i
        results[i] = { ok: true, value }
      catch error
        results[i] = { ok: false, error }
    return

  workers = (worker() for _ in [0...Math.min(limit, n)])
  await Promise.all workers
  results

export default pMap
