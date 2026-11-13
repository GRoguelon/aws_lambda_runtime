defmodule AWS.Lambda.Runtime.Release do
  @moduledoc """
  `mix release` configuration turning a plain release into a package for
  Lambda's `provided.al2023` runtime. See `lambda/1`.
  """

  alias AWS.Lambda.Runtime.Handler

  ## Module attributes

  # Where the builder image keeps the shared libraries the OTP layer ships
  # alongside ERTS, and that the Lambda sandbox doesn't have.
  @shared_libs_path "/opt/lib"

  ## Public functions

  @doc """
  Returns the options of a Lambda release.

  The defaults are `include_erts: false` (ERTS comes from the OTP layer),
  `include_executables_for: [:unix]`, `strip_beams: true`, `quiet: true` and a
  `rel_templates_path` providing the `vm.args`, `env.sh` and `bootstrap` files
  Lambda expects. Any `mix release` option given in `opts` overrides them.

  With `include_erts: true`, the release embeds ERTS and the function needs no
  OTP layer: `bundle_shared_libs/1` is then added after `:assemble`. Build it
  with `mix aws_lambda.build`, so the ERTS embedded is one built for Lambda.

  The release must be named `lambda`, as `bootstrap` starts `bin/lambda`.

  ## Options

    * `:handler` - the function's handler, as a module (calling its
      `handler/2`), a `{module, function}` pair or a handler string (see
      `AWS.Lambda.Runtime.Handler`). It takes precedence over
      `config :aws_lambda_runtime, :handler` and the function's *Handler*
      setting. The module must be compiled and export the function with an
      arity of 2, which is checked here, so a typo fails the build rather than
      the cold start.
    * `:strip_iex` - when `true`, removes IEx from the release with
      `strip_iex/1`.
    * `:before_steps` - a list of steps to run before the other steps.
    * `:after_steps` - a list of steps to run after the other steps.

  Call it from an anonymous function in `mix.exs`, so it only runs once
  `:aws_lambda_runtime` is compiled:

      releases: [
        lambda: fn -> AWS.Lambda.Runtime.Release.lambda(handler: MyApp.Handler) end
      ]
  """
  @spec lambda(keyword()) :: keyword()
  def lambda(opts \\ []) do
    {custom_opts, opts} = Keyword.split(opts, ~w[handler strip_iex before_steps after_steps]a)

    steps =
      if Keyword.get(opts, :include_erts, false) == false do
        [:assemble]
      else
        [:assemble, &__MODULE__.bundle_shared_libs/1]
      end

    [
      include_erts: false,
      include_executables_for: [:unix],
      strip_beams: true,
      quiet: true,
      rel_templates_path: priv_path("priv/rel"),
      steps: steps
    ]
    |> Keyword.merge(opts)
    |> maybe_put_handler(custom_opts)
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

  @doc """
  Release step copying the shared libraries ERTS needs and the Lambda sandbox
  lacks (`libcrypto`, `libssl`, `libtinfo`, `libstdc++`…) into the release's
  `lib/` directory, which Lambda puts on `LD_LIBRARY_PATH`. The OTP layer
  ships them in `/opt/lib`, so a release embedding ERTS must carry them.

  They are taken from `source`, the builder image's `/opt/lib`. Raises when it
  doesn't exist: the release is then not built in that image, and the ERTS it
  embeds wouldn't run on Lambda.

  Added by `lambda/1` after `:assemble` when ERTS is included.
  """
  @spec bundle_shared_libs(Mix.Release.t(), Path.t()) :: Mix.Release.t()
  def bundle_shared_libs(release, source \\ @shared_libs_path) do
    unless File.dir?(source) do
      raise ArgumentError, """
      the release includes ERTS, but #{source} doesn't exist, so it isn't \
      built in the Lambda builder image: the ERTS it embeds wouldn't run on \
      Lambda. Build it with `mix aws_lambda.build`, or set include_erts: false \
      to use the OTP layer.
      """
    end

    destination = Path.join(release.path, "lib")

    for name <- File.ls!(source), File.regular?(Path.join(source, name)) do
      File.cp!(Path.join(source, name), Path.join(destination, name))
    end

    release
  end

  ## Private functions

  defp priv_path(path) do
    Application.app_dir(:aws_lambda_runtime, path)
  end

  # Stored in the release's options for env.sh.eex, which exports it as
  # RELEASE_LAMBDA_HANDLER, read by AWS.Lambda.Runtime.Handler.resolve!/0.
  defp maybe_put_handler(release, opts) do
    case Keyword.fetch(opts, :handler) do
      {:ok, handler} ->
        Keyword.put(release, :aws_lambda_runtime, handler: handler_string!(handler))

      :error ->
        release
    end
  end

  defp handler_string!(handler) do
    {module, function} = Handler.parse!(handler)

    unless Code.ensure_loaded?(module) and function_exported?(module, function, 2) do
      raise ArgumentError,
            "the handler #{inspect(module)}.#{function}/2 doesn't exist: " <>
              "the module must be compiled and export the function with an arity of 2"
    end

    inspect(module) <> "." <> Atom.to_string(function)
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
