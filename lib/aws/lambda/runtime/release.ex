defmodule AWS.Lambda.Runtime.Release do
  @moduledoc """
  `mix release` configuration turning a plain release into a package for
  Lambda's `provided.al2023` runtime. See `lambda/1`.
  """

  ## Public functions

  @doc """
  Returns the options of a Lambda release.

  The defaults are `include_erts: false` (ERTS comes from the OTP layer),
  `include_executables_for: [:unix]`, `strip_beams: true`, `quiet: true` and a
  `rel_templates_path` providing the `vm.args`, `env.sh` and `bootstrap` files
  Lambda expects. Any `mix release` option given in `opts` overrides them.

  The release must be named `lambda`, as `bootstrap` starts `bin/lambda`.

  ## Options

    * `:strip_iex` - when `true`, removes IEx from the release with
      `strip_iex/1`.
    * `:before_steps` - a list of steps to run before the other steps.
    * `:after_steps` - a list of steps to run after the other steps.

  Call it from an anonymous function in `mix.exs`, so it only runs once
  `:aws_lambda_runtime` is compiled:

      releases: [lambda: fn -> AWS.Lambda.Runtime.Release.lambda(strip_iex: true) end]
  """
  @spec lambda(keyword()) :: keyword()
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

  @doc """
  Release step removing the `:iex` application from the release and its boot
  scripts, for a smaller package. `bin/lambda remote` won't work without it.
  """
  @spec strip_iex(Mix.Release.t()) :: Mix.Release.t()
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
    before_steps = Keyword.get(opts, :before_steps)

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
