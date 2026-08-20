defmodule AWS.Lambda.Runtime.Application do
  @moduledoc """
  OTP application entry point.

  Supervises the `Task.Supervisor` that bounds handler invocations and the
  `AWS.Lambda.Runtime` loop itself, one-for-one.

  The runtime loop can be disabled with

      config :aws_lambda_runtime, start_runtime: false

  which is how this library's own test suite avoids looping against a
  Runtime API that doesn't exist in the test environment.
  """

  use Application

  ## Public functions

  @doc "Starts the application supervision tree. Called by the OTP boot process."
  @impl Application
  def start(_type, _args) do
    children =
      [{Task.Supervisor, name: AWS.Lambda.Runtime.TaskSupervisor}] ++ runtime_child()

    opts = [strategy: :one_for_one, name: AWS.Lambda.Runtime.Supervisor]
    Supervisor.start_link(children, opts)
  end

  ## Private functions

  defp runtime_child do
    if Application.get_env(:aws_lambda_runtime, :start_runtime, true) do
      [AWS.Lambda.Runtime]
    else
      []
    end
  end
end
