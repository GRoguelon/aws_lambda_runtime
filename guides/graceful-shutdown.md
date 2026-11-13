# Graceful shutdown

Lambda shuts an execution environment down after it has been idle for a
while, or when the function is updated. To flush a buffer or close a
connection then, implement the handler's `terminate/2`, called with
`:shutdown` and `init/1`'s state:

```elixir
@impl true
def terminate(_reason, _state) do
  HelloFunction.Metrics.flush()
end
```

Code outside the handler, a library for instance, can register a function
of its own with `AWS.Lambda.Runtime.Shutdown.register/1`, before the first
invocation.

Lambda only sends a SIGTERM before shutting an environment down when an
extension is registered in it: with `terminate/2` or a function registered,
the runtime registers itself as an internal extension during the init phase,
so no extension layer is needed.

On SIGTERM, `terminate/2` and the registered functions run in order while
every application is still running, `Logger` is flushed, then the VM stops its applications,
which also runs their `stop/1` callbacks and the `terminate/2` of the
processes trapping exits. Lambda allows about 500 milliseconds for all of
it before killing the environment, so keep these functions short.
