defmodule AWS.Lambda.Runtime.Shutdown do
  @moduledoc """
  Runs functions when Lambda shuts the execution environment down, to flush
  what the function buffered or close what it opened.

      def start(_type, _args) do
        AWS.Lambda.Runtime.Shutdown.register(fn -> MyApp.Metrics.flush() end)

        Supervisor.start_link(children, strategy: :one_for_one)
      end

  Lambda only warns an execution environment that it is shutting down, with
  a SIGTERM, when an extension is registered in it. When a function is
  registered here, the runtime registers itself as an internal extension
  during the init phase, so no extension layer is needed. A function must
  therefore be registered before the first invocation, from the function's
  application for instance.

  On SIGTERM, the registered functions run one after the other, in the order
  they were registered, while every application is still running. A function
  that raises, throws or exits is logged, and the next one runs. `Logger` is
  flushed, then the VM stops its applications, the function's own first, as
  `System.stop/0` does.

  Lambda leaves little time for all of it, about 500 milliseconds with an
  internal extension, before killing the environment: keep these functions
  short.

  Installed by `:aws_lambda_runtime`'s application, the SIGTERM handler
  replaces the VM's default one, which stops the applications at once.
  SIGUSR1 and SIGQUIT keep their default behaviour.
  """

  @behaviour :gen_event

  require Logger

  ## Module attributes

  @hooks_key {__MODULE__, :hooks}

  ## Public functions

  @doc """
  Registers `fun` to be called when Lambda shuts the execution environment
  down. See the moduledoc.
  """
  @spec register((-> term())) :: :ok
  def register(fun) when is_function(fun, 0) do
    :persistent_term.put(@hooks_key, hooks() ++ [fun])
  end

  @doc "Whether a function is registered, so the runtime must ask for SIGTERM."
  @spec registered?() :: boolean()
  def registered? do
    hooks() != []
  end

  @doc """
  Replaces the VM's SIGTERM handler. `stop` is called once the registered
  functions have run, `System.stop/0` by default.
  """
  @spec install((-> term())) :: :ok | {:error, term()}
  def install(stop \\ &System.stop/0) do
    # Already installed when the application is restarted.
    if __MODULE__ in :gen_event.which_handlers(:erl_signal_server) do
      :ok
    else
      :gen_event.swap_handler(
        :erl_signal_server,
        {:erl_signal_handler, :swap},
        {__MODULE__, stop}
      )
    end
  end

  @doc """
  Calls the registered functions, flushes `Logger`, then calls `stop`.
  """
  @spec run((-> term())) :: term()
  def run(stop) do
    Logger.info("SIGTERM received, shutting down")

    for hook <- hooks() do
      try do
        hook.()
      catch
        kind, reason ->
          Logger.error(
            "shutdown function failed: " <> Exception.format(kind, reason, __STACKTRACE__)
          )
      end
    end

    Logger.flush()
    stop.()
  end

  ## Callbacks

  @doc false
  @impl :gen_event
  def init({stop, _swapped}) when is_function(stop, 0) do
    {:ok, stop}
  end

  def init(stop) when is_function(stop, 0) do
    {:ok, stop}
  end

  # The signal server must keep handling signals while the functions run.
  @doc false
  @impl :gen_event
  def handle_event(:sigterm, stop) do
    spawn(fn -> run(stop) end)

    {:ok, stop}
  end

  # What the VM's default handler does.
  def handle_event(:sigusr1, _stop) do
    :erlang.halt(~c"Received SIGUSR1")
  end

  def handle_event(:sigquit, _stop) do
    :erlang.halt()
  end

  def handle_event(_signal, stop) do
    {:ok, stop}
  end

  @doc false
  @impl :gen_event
  def handle_call(_request, stop) do
    {:ok, :ok, stop}
  end

  ## Private functions

  defp hooks do
    :persistent_term.get(@hooks_key, [])
  end
end
