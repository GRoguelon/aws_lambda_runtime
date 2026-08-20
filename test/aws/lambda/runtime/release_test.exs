defmodule AWS.Lambda.Runtime.ReleaseTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias AWS.Lambda.Runtime.Release

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "aws_lambda_runtime_release_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)

    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, dir: dir}
  end

  describe "copy_bootstrap/1" do
    test "copies priv/bootstrap to the release root as an executable file", %{dir: dir} do
      release = %{path: dir}

      assert ^release = Release.copy_bootstrap(release)

      bootstrap_path = Path.join(dir, "bootstrap")
      assert File.exists?(bootstrap_path)
      assert File.read!(bootstrap_path) == File.read!("priv/bootstrap")

      stat = File.stat!(bootstrap_path)
      assert (stat.mode &&& 0o777) == 0o755
    end
  end

  describe "copy_release_files/1" do
    test "renders vm.args, env.sh and remote.vm.args into version_path", %{dir: dir} do
      release = %{version_path: dir}

      assert ^release = Release.copy_release_files(release)

      for {template, target} <- [
            {"vm.args.eex", "vm.args"},
            {"env.sh.eex", "env.sh"},
            {"remote.vm.args.eex", "remote.vm.args"}
          ] do
        rendered = File.read!(Path.join(dir, target))
        source = File.read!(Path.join("priv/rel", template))

        assert rendered == source
      end
    end
  end
end
