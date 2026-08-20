defmodule AWS.Lambda.Runtime.Release do
  @moduledoc """
  `mix release` steps wired in by `AWS.Lambda.Runtime.MixRelease.releases/1` to
  turn a plain release into a Lambda-ready package.
  """

  ## Public functions

  def lambda(opts \\ []) do
    {custom_opts, opts} = Keyword.split(opts, ~w[strip_iex before_steps after_steps]a)

    [
      include_erts: false,
      include_executables_for: [:unix],
      strip_beams: true,
      quiet: true,
      rel_templates_path: priv_path("priv/rel"),
      steps: [:assemble]
    ]
    |> Keyword.merge(opts)
    |> maybe_strip_iex(custom_opts)
    |> maybe_before_steps(custom_opts)
    |> maybe_after_steps(custom_opts)
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

  ## Private functions

  defp priv_path(path) do
    Application.app_dir(:aws_lambda_runtime, path)
  end

  defp maybe_strip_iex(release, opts) do
    if Keyword.get(opts, :strip_iex) == true do
      Keyword.update!(release, :steps, fn steps -> [(&strip_iex/1) | steps] end)
    else
      release
    end
  end

  defp maybe_before_steps(release, opts) do
    before_steps = Keyword.get(opts, :before_steps) |> IO.inspect(label: "Value")

    cond do
      is_list(before_steps) ->
        Keyword.update(release, :steps, before_steps ++ [:assemble], &(before_steps ++ &1))

      not is_nil(before_steps) ->
        raise ArgumentError,
              "The option `before_steps` must be a list, got: #{inspect(before_steps)}"

      true ->
        release
    end
  end

  defp maybe_after_steps(release, opts) do
    after_steps = Keyword.get(opts, :after_steps)

    cond do
      is_list(after_steps) ->
        Keyword.update(release, :steps, [:assemble] ++ after_steps, &(&1 ++ after_steps))

      not is_nil(after_steps) ->
        raise ArgumentError,
              "The option `after_steps` must be a list, got: #{inspect(after_steps)}"

      true ->
        release
    end
  end
end
