defmodule AWS.Lambda.Runtime.Logging do
  @moduledoc """
  Applies the function's logging configuration, which Lambda passes as
  environment variables:

    * `AWS_LAMBDA_LOG_FORMAT` set to `JSON` switches the default handler to
      `AWS.Lambda.Runtime.LogFormatter`, one JSON object per line.
    * `AWS_LAMBDA_LOG_LEVEL` (`TRACE`, `DEBUG`, `INFO`, `WARN`, `ERROR` or
      `FATAL`) sets `Logger`'s level, in both log formats. `TRACE` maps to
      `:debug`, Logger's lowest level.

  The level is, by priority:

    1. `AWS_LAMBDA_LOG_LEVEL`, so it can be changed in the function's
       configuration without a new deployment. A warning is logged when it
       differs from `config :logger, level: ...`;
    2. `config :logger, level: ...`;
    3. `:info` when running from a release (its start script sets
       `RELEASE_ROOT`), as on Lambda. Elsewhere (`iex -S mix`, tests)
       Logger's default, `:debug`, stands.

  Called when `:aws_lambda_runtime` starts, before the function's own
  application, so its first messages already follow the configuration.
  """

  require Logger

  ## Module attributes

  @default_level :info

  ## Public functions

  @doc """
  Applies the configuration found in `env`, a map of environment variables
  (`System.get_env/0` by default), over the application's `:logger` config.
  """
  @spec configure(%{String.t() => String.t()}) :: :ok
  def configure(env \\ System.get_env()) do
    # First, so the level warning below is already formatted as JSON. An app
    # may have disabled the default handler (config :logger,
    # :default_handler, false): then there is nothing to format.
    if Map.get(env, "AWS_LAMBDA_LOG_FORMAT") == "JSON" do
      case :logger.update_handler_config(
             :default,
             :formatter,
             {AWS.Lambda.Runtime.LogFormatter, %{}}
           ) do
        :ok -> :ok
        {:error, {:not_found, :default}} -> :ok
      end
    end

    lambda_level = Map.get(env, "AWS_LAMBDA_LOG_LEVEL", "")
    configured = Application.get_env(:logger, :level)

    case {level(lambda_level), configured} do
      {nil, nil} ->
        if Map.has_key?(env, "RELEASE_ROOT") do
          Logger.configure(level: @default_level)
        end

      # Logger applied the configured level when it started.
      {nil, _configured} ->
        :ok

      {level, configured} when configured in [nil, level] ->
        Logger.configure(level: level)

      {level, configured} ->
        override(level, lambda_level, configured)
    end

    :ok
  end

  @doc """
  Maps a Lambda log level to a `Logger` level, or `nil` for an unknown one.
  """
  @spec level(String.t()) :: Logger.level() | nil
  def level(name) do
    case String.upcase(name) do
      "TRACE" -> :debug
      "DEBUG" -> :debug
      "INFO" -> :info
      "WARN" -> :warning
      "ERROR" -> :error
      "FATAL" -> :critical
      _unknown -> nil
    end
  end

  ## Private functions

  # The warning is logged under whichever of the two levels lets it through:
  # after the change when the new level is more verbose, before otherwise.
  defp override(level, lambda_level, configured) do
    message =
      "AWS_LAMBDA_LOG_LEVEL=#{lambda_level} overrides config :logger, " <>
        "level: #{inspect(configured)}; logging at #{inspect(level)}"

    if Logger.compare_levels(level, :warning) == :gt do
      Logger.warning(message)
      Logger.configure(level: level)
    else
      Logger.configure(level: level)
      Logger.warning(message)
    end
  end
end
