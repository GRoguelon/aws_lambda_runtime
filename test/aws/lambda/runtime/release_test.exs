defmodule AWS.Lambda.Runtime.ReleaseTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias AWS.Lambda.Runtime.Release

  describe "lambda/1" do
    test "returns the Lambda defaults" do
      release = Release.lambda()

      assert release[:include_erts] == false
      assert release[:include_executables_for] == [:unix]
      assert release[:strip_beams] == true
      assert release[:quiet] == true
      assert release[:steps] == [:assemble]
      assert release[:rel_templates_path] == Application.app_dir(:aws_lambda_runtime, "priv/rel")
    end

    test "ships an executable bootstrap overlay" do
      bootstrap_path = Path.join(Release.lambda()[:rel_templates_path], "overlays/bootstrap")

      assert File.exists?(bootstrap_path)
      assert (File.stat!(bootstrap_path).mode &&& 0o777) == 0o755
    end

    test "lets mix release options override the defaults" do
      release = Release.lambda(include_erts: true, quiet: false, steps: [:assemble, :tar])

      assert release[:include_erts] == true
      assert release[:quiet] == false
      assert release[:steps] == [:assemble, :tar]
    end

    test "doesn't leak its own options into the release" do
      release = Release.lambda(strip_iex: true, before_steps: [], after_steps: [])

      refute Keyword.has_key?(release, :strip_iex)
      refute Keyword.has_key?(release, :before_steps)
      refute Keyword.has_key?(release, :after_steps)
    end

    test "prepends strip_iex/1 to the steps when strip_iex is true" do
      assert [strip_iex, :assemble] = Release.lambda(strip_iex: true)[:steps]
      assert is_function(strip_iex, 1)

      assert Release.lambda(strip_iex: false)[:steps] == [:assemble]
    end

    test "places before_steps and after_steps around the steps" do
      before_step = fn release -> release end
      after_step = fn release -> release end

      assert Release.lambda(before_steps: [before_step], after_steps: [after_step, :tar])[:steps] ==
               [before_step, :assemble, after_step, :tar]
    end

    test "runs before_steps ahead of strip_iex/1" do
      before_step = fn release -> release end

      assert [^before_step, strip_iex, :assemble] =
               Release.lambda(strip_iex: true, before_steps: [before_step])[:steps]

      assert is_function(strip_iex, 1)
    end

    test "raises when before_steps isn't a list" do
      assert_raise ArgumentError, ~r/`before_steps` must be a list, got: :tar/, fn ->
        Release.lambda(before_steps: :tar)
      end
    end

    test "raises when after_steps isn't a list" do
      assert_raise ArgumentError, ~r/`after_steps` must be a list, got: :tar/, fn ->
        Release.lambda(after_steps: :tar)
      end
    end
  end

  describe "strip_iex/1" do
    test "removes IEx from the applications and the boot scripts" do
      release = %{
        applications: %{
          iex: [modules: [IEx]],
          elixir: [modules: [:iex, Enum]]
        },
        boot_scripts: %{
          start: [kernel: :permanent, elixir: :permanent, iex: :none],
          start_clean: [kernel: :permanent, iex: :none]
        }
      }

      assert %{applications: applications, boot_scripts: boot_scripts} =
               Release.strip_iex(release)

      assert applications == %{elixir: [modules: [Enum]]}
      assert boot_scripts.start == [kernel: :permanent, elixir: :permanent]
      assert boot_scripts.start_clean == [kernel: :permanent]
    end
  end
end
