defmodule AWS.Lambda.Runtime.LoggingTest do
  # Changes the global Logger configuration.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias AWS.Lambda.Runtime.Logging

  setup do
    level = Logger.level()
    configured = Application.fetch_env(:logger, :level)

    # ExUnit's `capture_log: true` removes the default handler while the
    # suite runs: give the tests a silent one to configure.
    added? = match?({:error, {:not_found, :default}}, :logger.get_handler_config(:default))
    if added?, do: :ok = :logger.add_handler(:default, :logger_std_h, %{level: :none})
    {:ok, %{formatter: formatter} = handler} = :logger.get_handler_config(:default)

    on_exit(fn ->
      Logger.configure(level: level)
      _ = :logger.remove_handler(:default)

      unless added?,
        do: :ok = :logger.add_handler(:default, handler.module, handler)

      case configured do
        {:ok, value} -> Application.put_env(:logger, :level, value)
        :error -> Application.delete_env(:logger, :level)
      end
    end)

    %{formatter: formatter}
  end

  describe "level/1" do
    test "maps Lambda's levels to Logger's" do
      assert Logging.level("TRACE") == :debug
      assert Logging.level("DEBUG") == :debug
      assert Logging.level("INFO") == :info
      assert Logging.level("WARN") == :warning
      assert Logging.level("ERROR") == :error
      assert Logging.level("FATAL") == :critical
      assert Logging.level("warn") == :warning
      assert Logging.level("VERBOSE") == nil
      assert Logging.level("") == nil
    end
  end

  describe "configure/1, level" do
    test "uses AWS_LAMBDA_LOG_LEVEL when the app configures none" do
      app_level(nil)

      log = capture_log(fn -> Logging.configure(%{"AWS_LAMBDA_LOG_LEVEL" => "ERROR"}) end)

      assert Logger.level() == :error
      assert log == ""
    end

    test "prefers AWS_LAMBDA_LOG_LEVEL over the app's level, with a warning" do
      app_level(:info)

      log = capture_log(fn -> Logging.configure(%{"AWS_LAMBDA_LOG_LEVEL" => "DEBUG"}) end)

      assert Logger.level() == :debug
      assert log =~ "AWS_LAMBDA_LOG_LEVEL=DEBUG overrides config :logger, level: :info"
    end

    test "logs the warning even when the new level hides warnings" do
      app_level(:info)

      log = capture_log(fn -> Logging.configure(%{"AWS_LAMBDA_LOG_LEVEL" => "ERROR"}) end)

      assert Logger.level() == :error
      assert log =~ "AWS_LAMBDA_LOG_LEVEL=ERROR overrides config :logger, level: :info"
    end

    test "doesn't warn when both levels agree" do
      app_level(:warning)

      log = capture_log(fn -> Logging.configure(%{"AWS_LAMBDA_LOG_LEVEL" => "WARN"}) end)

      assert Logger.level() == :warning
      assert log == ""
    end

    test "keeps the app's level without AWS_LAMBDA_LOG_LEVEL" do
      app_level(:warning)

      Logging.configure(%{"RELEASE_ROOT" => "/var/task"})

      assert Logger.level() == :warning
    end

    test "treats an unknown AWS_LAMBDA_LOG_LEVEL as unset" do
      app_level(:warning)

      Logging.configure(%{"AWS_LAMBDA_LOG_LEVEL" => "VERBOSE"})

      assert Logger.level() == :warning
    end

    test "defaults to :info in a release when neither sets a level" do
      app_level(nil)

      Logging.configure(%{"RELEASE_ROOT" => "/var/task"})

      assert Logger.level() == :info
    end

    test "keeps Logger's :debug outside a release when neither sets a level" do
      app_level(nil)
      Logger.configure(level: :debug)

      Logging.configure(%{})

      assert Logger.level() == :debug
    end
  end

  describe "configure/1, format" do
    test "installs the JSON formatter for AWS_LAMBDA_LOG_FORMAT=JSON" do
      assert :ok = Logging.configure(%{"AWS_LAMBDA_LOG_FORMAT" => "JSON"})

      assert {:ok, %{formatter: {AWS.Lambda.Runtime.LogFormatter, %{}}}} =
               :logger.get_handler_config(:default)
    end

    test "does nothing without a default handler" do
      :ok = :logger.remove_handler(:default)

      assert :ok = Logging.configure(%{"AWS_LAMBDA_LOG_FORMAT" => "JSON"})
    end

    test "keeps the formatter for any other format", %{formatter: formatter} do
      assert :ok = Logging.configure(%{"AWS_LAMBDA_LOG_FORMAT" => "Text"})

      assert {:ok, %{formatter: ^formatter}} = :logger.get_handler_config(:default)
    end
  end

  # Simulates `config :logger, level: level`, applied by Logger at boot.
  defp app_level(nil) do
    Application.delete_env(:logger, :level)
  end

  defp app_level(level) do
    Application.put_env(:logger, :level, level)
    Logger.configure(level: level)
  end
end
