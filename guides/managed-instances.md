# Lambda Managed Instances

On Lambda Managed Instances, an execution environment handles several
invocations at once, as many as Lambda sets in `AWS_LAMBDA_MAX_CONCURRENCY`.
The runtime then polls for that many invocations, each handled in its own
process, as on standard Lambda, with nothing to change in the handler:

- `init/1` still runs once, and its state is shared by every invocation,
  which can only read it.
- Each invocation's logs carry its request ID, and X-Ray subsegments attach
  to its own trace: the trace header lives in the handler's process rather
  than in `_X_AMZN_TRACE_ID`, which isn't set then. A process the handler
  starts, such as a `Task`, attaches to it with
  `trace_header: XRay.trace_header()`.
- Only the environment's first invocation is a cold start, for the
  telemetry events.
- The VM keeps its own scheduler count, from the instance's vCPUs, rather
  than deriving it from the memory size as on standard Lambda.
- Lambda doesn't stop a handler at its deadline there: the runtime does, as
  everywhere.
