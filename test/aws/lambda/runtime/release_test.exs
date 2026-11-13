defmodule AWS.Lambda.Runtime.ReleaseTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias AWS.Lambda.Runtime.Release

  defmodule TestHandler do
    @moduledoc false
    def handler(event, _context), do: event
    def process(event, _context), do: event
  end

  defmodule NewHandler do
    @moduledoc false
    def handle(event, _context, _state), do: event
  end

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

    test "stores the handler as a handler string" do
      assert Release.lambda(handler: TestHandler)[:aws_lambda_runtime] ==
               [handler: "AWS.Lambda.Runtime.ReleaseTest.TestHandler.handler"]

      assert Release.lambda(handler: {TestHandler, :process})[:aws_lambda_runtime] ==
               [handler: "AWS.Lambda.Runtime.ReleaseTest.TestHandler.process"]

      assert Release.lambda(handler: "AWS.Lambda.Runtime.ReleaseTest.TestHandler")[
               :aws_lambda_runtime
             ] == [handler: "AWS.Lambda.Runtime.ReleaseTest.TestHandler.handler"]

      assert Release.lambda(handler: NewHandler)[:aws_lambda_runtime] ==
               [handler: "AWS.Lambda.Runtime.ReleaseTest.NewHandler.handle"]

      refute Keyword.has_key?(Release.lambda(), :aws_lambda_runtime)
      refute Keyword.has_key?(Release.lambda(handler: TestHandler), :handler)
    end

    test "raises when the handler doesn't exist" do
      assert_raise ArgumentError, ~r/NoSuch.Handler.handler\/2 doesn't exist/, fn ->
        Release.lambda(handler: NoSuch.Handler)
      end

      assert_raise ArgumentError, ~r/TestHandler.missing\/2 doesn't exist/, fn ->
        Release.lambda(handler: {TestHandler, :missing})
      end
    end

    test "adds bundle_shared_libs/1 after :assemble when ERTS is included" do
      bundle = &Release.bundle_shared_libs/1

      assert Release.lambda(include_erts: true)[:steps] == [:assemble, bundle]
      assert Release.lambda(include_erts: "/path/to/erts")[:steps] == [:assemble, bundle]

      assert [strip_iex, :assemble, ^bundle, :tar] =
               Release.lambda(include_erts: true, strip_iex: true, after_steps: [:tar])[:steps]

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

  describe "env.sh" do
    test "exports the release's handler" do
      env_sh = render_env_sh(Release.lambda(handler: TestHandler))

      assert env_sh =~
               ~s(export RELEASE_LAMBDA_HANDLER="AWS.Lambda.Runtime.ReleaseTest.TestHandler.handler")
    end

    test "exports no handler when the release has none" do
      refute render_env_sh(Release.lambda()) =~ "RELEASE_LAMBDA_HANDLER="
    end

    @tag :tmp_dir
    test "runs one scheduler per vCPU Lambda allocates", %{tmp_dir: tmp_dir} do
      assert schedulers(tmp_dir, %{"AWS_LAMBDA_FUNCTION_MEMORY_SIZE" => "512"}) == "+S 1:1"
      assert schedulers(tmp_dir, %{"AWS_LAMBDA_FUNCTION_MEMORY_SIZE" => "3008"}) == "+S 2:2"
      assert schedulers(tmp_dir, %{"AWS_LAMBDA_FUNCTION_MEMORY_SIZE" => "10240"}) == "+S 6:6"
    end

    @tag :tmp_dir
    test "leaves the scheduler count alone when it can't or mustn't derive it", %{
      tmp_dir: tmp_dir
    } do
      assert schedulers(tmp_dir, %{}) == ""

      assert schedulers(tmp_dir, %{
               "AWS_LAMBDA_FUNCTION_MEMORY_SIZE" => "512",
               "ELIXIR_ERL_OPTIONS" => "+S 3:3"
             }) == "+S 3:3"

      # Lambda Managed Instances: the vCPUs don't follow the memory size.
      assert schedulers(tmp_dir, %{
               "AWS_LAMBDA_FUNCTION_MEMORY_SIZE" => "4096",
               "AWS_LAMBDA_MAX_CONCURRENCY" => "8"
             }) == ""
    end

    # The ELIXIR_ERL_OPTIONS env.sh leaves, run by sh as the release does.
    defp schedulers(tmp_dir, env) do
      path = Path.join(tmp_dir, "env.sh")
      File.write!(path, render_env_sh(Release.lambda()))

      env =
        Enum.map(
          ~w[AWS_LAMBDA_FUNCTION_MEMORY_SIZE AWS_LAMBDA_MAX_CONCURRENCY ELIXIR_ERL_OPTIONS],
          &{&1, Map.get(env, &1)}
        )

      {output, 0} =
        System.cmd("sh", ["-c", ~s(. "$1"; printf %s "$ELIXIR_ERL_OPTIONS"), "sh", path],
          env: env
        )

      output
    end

    defp render_env_sh(options) do
      options[:rel_templates_path]
      |> Path.join("env.sh.eex")
      |> EEx.eval_file(assigns: [release: %{options: options}])
    end
  end

  describe "bundle_shared_libs/2" do
    @describetag :tmp_dir

    test "copies the shared libraries into the release's lib", %{tmp_dir: tmp_dir} do
      source = Path.join(tmp_dir, "opt-lib")
      release = %{path: Path.join(tmp_dir, "rel")}

      File.mkdir_p!(Path.join(source, "subdir"))
      File.mkdir_p!(Path.join(release.path, "lib"))
      File.write!(Path.join(source, "libcrypto.so.3"), "crypto")
      File.write!(Path.join(source, "libtinfo.so.6"), "tinfo")

      assert Release.bundle_shared_libs(release, source) == release

      assert release.path |> Path.join("lib") |> File.ls!() |> Enum.sort() ==
               ["libcrypto.so.3", "libtinfo.so.6"]

      assert File.read!(Path.join(release.path, "lib/libcrypto.so.3")) == "crypto"
    end

    test "raises outside of the builder image", %{tmp_dir: tmp_dir} do
      assert_raise ArgumentError, ~r/mix aws_lambda.build/, fn ->
        Release.bundle_shared_libs(%{path: tmp_dir}, Path.join(tmp_dir, "missing"))
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
