# Framework default agent entry.
#
# Used by `pipeline run` when the project has NO agent.coffee of its own. It is
# the minimal, batteries-included loop body — discover every <id>/activity.yaml,
# run each activity's pipeline each tick, own the engine (PID guard, graceful
# shutdown, field-index, status meter). Projects that need to customize the loop
# drop an agent.coffee at their root and `pipeline run` will prefer that instead.
import { runPipeline } from '../index.coffee'

await runPipeline()
