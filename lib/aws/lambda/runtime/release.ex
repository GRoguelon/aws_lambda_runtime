defmodule AWS.Lambda.Runtime.Release do
  @moduledoc """
  `mix release` steps wired in by `AWS.Lambda.Runtime.MixRelease.releases/1` to
  turn a plain release into a Lambda-ready package.
  """

  ## Module attributes

  @rel_files [
    {"vm.args.eex", "vm.args"},
    {"env.sh.eex", "env.sh"},
    {"remote.vm.args.eex", "remote.vm.args"}
  ]

  ## Public functions

  @doc """
  Copies `priv/bootstrap` to the root of the release and makes it executable.

  This is the entrypoint Lambda invokes for a `provided.al2023` function.
  """
  def copy_bootstrap(release) do
    target = Path.join(release.path, "bootstrap")
    bootstrap_path = priv_path("priv/bootstrap")

    File.cp!(bootstrap_path, target)
    File.chmod!(target, 0o755)

    release
  end

  @doc """
  Renders our own vm.args/env.sh/remote.vm.args over Mix's generated defaults.

  Called as a step (after `:assemble`), so `:aws_lambda_runtime` is guaranteed
  to be compiled and loaded by the time `Application.app_dir/2` resolves its
  priv dir — unlike a `rel_templates_path` release option, which would need to
  be computed inside `mix.exs`'s `project/0`, before Mix has fetched or
  compiled any dependency.
  """
  def copy_release_files(release) do
    templates_dir = priv_path("priv/rel")

    for {template, target} <- @rel_files do
      content = templates_dir |> Path.join(template) |> EEx.eval_file(release: release)

      release.version_path
      |> Path.join(target)
      |> File.write!(content)
    end

    release
  end

  ## Private functions

  defp priv_path(path) do
    Application.app_dir(:aws_lambda_runtime, path)
  end
end
