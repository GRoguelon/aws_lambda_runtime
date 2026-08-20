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

  def lambda(opts \\ []) do
    [
      include_erts: false,
      include_executables_for: [:unix],
      strip_beams: true,
      quiet: true,
      steps: [:assemble, &copy_bootstrap/1, &copy_release_files/1]
    ]
    |> maybe_strip_iex(opts)
    |> maybe_before_steps(opts)
    |> maybe_after_steps(opts)
  end

  def strip_iex(%{applications: applications, boot_scripts: boot_scripts} = release) do
    applications =
      applications
      |> Map.delete(:iex)
      |> Map.update!(:elixir, fn elixir ->
        Keyword.update!(elixir, :modules, &List.delete(&1, :iex))
      end)

    boot_scripts =
      boot_scripts
      |> Map.update!(:start, &Keyword.delete(&1, :iex))
      |> Map.update!(:start_clean, &Keyword.delete(&1, :iex))

    %{release | applications: applications, boot_scripts: boot_scripts}
  end

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

  defp maybe_strip_iex(release, opts) do
    if Keyword.get(opts, :strip_iex) == true do
      Keyword.update!(release, :steps, &[(&strip_iex/1) | &1])
    else
      release
    end
  end

  defp maybe_before_steps(release, opts) do
    before_steps = Keyword.get(opts, :before_steps)

    if is_list(before_steps) do
      Keyword.update!(release, :steps, &(before_steps ++ &1))
    else
      release
    end
  end

  defp maybe_after_steps(release, opts) do
    after_steps = Keyword.get(opts, :after_steps)

    if is_list(after_steps) do
      Keyword.update!(release, :steps, &(&1 ++ after_steps))
    else
      release
    end
  end
end
