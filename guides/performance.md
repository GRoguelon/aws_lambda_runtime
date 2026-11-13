# Performance and tuning

## Performance

Rough numbers for the `HelloFunction` example of
[Getting started](getting-started.md), deployed on arm64 with
512MB of memory (Erlang 29.1.2, Elixir 1.20.5), medians of 20 cold starts:

- **Cold start:** ~495ms — ~455ms of init, then ~40ms for the first
  invocation, which loads the modules it uses, the release booting in
  interactive mode (see [Tuning the VM](#tuning-the-vm)).
- **Warm invocations:** ~2ms.
- **Memory used:** ~75MB.

## Tuning the VM

The release ships a `vm.args` tuned for Lambda: no scheduler busy waiting, no
distribution, and one scheduler per vCPU Lambda allocates, derived from the
function's memory size at start.

It also boots in interactive mode, loading each module the first time it is
called instead of all of them at boot, which shortens the init phase. Set the
function's `RELEASE_MODE` environment variable to `embedded` to preload every
module instead, so the first invocation doesn't pay for loading them.

Any other [`erl` flag](https://www.erlang.org/doc/apps/erts/erl_cmd.html) can
be added through the function's `ELIXIR_ERL_OPTIONS` environment variable,
without rebuilding the package. For instance, a handler building large terms
may garbage collect less with a bigger initial process heap (`+hms`, in words;
the default is 233):

```sh
aws lambda update-function-configuration --function-name elixir-hello \
  --environment '{"Variables": {"ELIXIR_ERL_OPTIONS": "+hms 1024"}}'
```

`--environment` replaces all the function's variables, so include the existing
ones. An `+S` given this way overrides the scheduler count derived from the
memory size.
