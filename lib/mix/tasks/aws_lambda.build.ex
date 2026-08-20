defmodule Mix.Tasks.AwsLambda.Build do
  use Mix.Task

  @shortdoc "Packages a Lambda release into a deployable zip using the Elixir builder image"

  @moduledoc """
  Builds this project's Lambda release inside the prebuilt Elixir builder
  image and downloads the resulting deployment zip.

  Run from your function app's directory, passing the Erlang and Elixir
  versions to build with:

      mix aws_lambda.build 29.0.5 1.20.3

  ## What it does

    1. Pulls the `ghcr.io/groguelon/lambda-layer-elixir:<elixir>-erlang-<erlang>-arm64`
       image, erroring out if no image matches the given versions.
    2. Creates a container from that image.
    3. Installs `tar` (and any `--dep` packages) in the container via `dnf`
       (the image doesn't ship with `tar`).
    4. Copies this app's source into it.
    5. Runs `mix deps.get` and `mix release` inside the container (fetching
       `:aws_lambda_runtime` and any other declared deps).
    6. Zips the release directory inside the container.
    7. Copies the zip back out to the host.
    8. Removes the container.

  ## Options

    * `--release` / `-r` - name of the release to build. Defaults to the
      first release declared in `mix.exs`.
    * `--output` / `-o` - where to write the zip on the host. Defaults to
      `_build/<release>.zip`.
    * `--platform` - Docker platform to run for. Defaults to `linux/arm64`.
    * `--dep` / `-d` - extra `dnf` package to install in the container
      alongside `tar` (e.g. because a dep needs `git` to fetch). May be
      given multiple times.
  """

  ## Module attributes

  @image_prefix "ghcr.io/groguelon/lambda-layer-elixir"
  @default_platform "linux/arm64"

  ## Public functions

  @doc "Entry point invoked by `mix aws_lambda.build`. See the moduledoc for details."
  @impl Mix.Task
  def run(args) do
    {opts, args} =
      OptionParser.parse!(args,
        strict: [
          release: :string,
          output: :string,
          platform: :string,
          dep: [:string, :keep]
        ],
        aliases: [r: :release, o: :output, d: :dep]
      )

    {erlang_version, elixir_version} =
      case args do
        [erlang_version, elixir_version] ->
          {erlang_version, elixir_version}

        _ ->
          Mix.raise(
            "expected an Erlang version and an Elixir version, " <>
              "e.g. `mix aws_lambda.build 29.0.5 1.20.3`"
          )
      end

    ensure_executable!("docker")
    ensure_executable!("tar")

    app_root = File.cwd!()
    app_name = Path.basename(app_root)

    release = opts[:release] || default_release()
    platform = opts[:platform] || @default_platform
    image = "#{@image_prefix}:#{elixir_version}-erlang-#{erlang_version}-arm64"
    output = Path.expand(opts[:output] || Path.join("_build", "#{release}.zip"), app_root)
    dnf_packages = ["tar" | Keyword.get_values(opts, :dep)]

    container = "#{app_name}-lambda-build-#{System.unique_integer([:positive])}"

    step("==> Pulling builder image (#{image})")
    pull_image!(image, platform)

    step("==> Creating container #{container}")
    create_container!(container, image, platform)

    try do
      step("==> Installing #{Enum.join(dnf_packages, ", ")} in container")
      install_dnf_packages!(container, dnf_packages)

      step("==> Copying source into container")
      copy_source!(container, app_root)

      step("==> Packaging release (mix release #{release})")
      package_release!(container, app_name, release)

      step("==> Zipping build")
      zip_release!(container, app_name, release)

      step("==> Downloading build")
      download_zip!(container, output)

      Mix.shell().info([:green, "==> wrote #{output}"])
    after
      step("==> Removing container")
      docker(["rm", "-f", container])
    end
  end

  ## Private functions

  defp step(message), do: Mix.shell().info([:magenta, message])

  defp default_release do
    case Mix.Project.config()[:releases] do
      [{name, _config} | _rest] -> to_string(name)
      _ -> Mix.raise("no releases declared in mix.exs and no --release given")
    end
  end

  defp pull_image!(image, platform) do
    case docker(["pull", "--platform", platform, image]) do
      :ok ->
        :ok

      {:error, _status} ->
        Mix.raise(
          "no builder image found for #{image}. Check that this Erlang/Elixir " <>
            "version combination has been published to #{@image_prefix}."
        )
    end
  end

  defp create_container!(container, image, platform) do
    docker!([
      "create",
      "--platform",
      platform,
      "--name",
      container,
      "--entrypoint",
      "/bin/sh",
      image,
      "-c",
      "sleep infinity"
    ])

    docker!(["start", container])
  end

  # The lambda-layer-elixir image is trimmed down to the Lambda runtime
  # deps (ca-certificates, ncurses-libs, unixODBC) and doesn't ship `tar`,
  # which we need to get the source into the container. `--dep` adds more
  # packages here, e.g. `git` for deps fetched over git.
  defp install_dnf_packages!(container, packages) do
    docker!(
      [
        "exec",
        container,
        "dnf",
        "-y",
        "--setopt=install_weak_deps=0",
        "--nodocs",
        "install"
      ] ++ packages
    )
  end

  # Tars the app directory on the host, excluding local build artifacts, then
  # uploads and extracts the tar inside the container. This avoids copying
  # host-compiled (non-Linux) _build/deps artifacts into the container.
  defp copy_source!(container, app_root) do
    tar_path = Path.join(System.tmp_dir!(), "#{container}.tar")

    tar!([
      "--no-xattrs",
      "--exclude=_build",
      "--exclude=deps",
      "--exclude=.git",
      "-cf",
      tar_path,
      "-C",
      Path.dirname(app_root),
      Path.basename(app_root)
    ])

    docker!(["exec", container, "mkdir", "-p", "/build"])
    docker!(["cp", tar_path, "#{container}:/build/source.tar"])

    docker!([
      "exec",
      "-w",
      "/build",
      container,
      "sh",
      "-c",
      "tar -xf source.tar && rm source.tar"
    ])
  after
    File.rm(Path.join(System.tmp_dir!(), "#{container}.tar"))
  end

  defp package_release!(container, app_name, release) do
    docker!([
      "exec",
      "-e",
      "MIX_ENV=prod",
      "-w",
      "/build/#{app_name}",
      container,
      "sh",
      "-c",
      "mix do deps.get + release #{release}"
    ])
  end

  defp zip_release!(container, app_name, release) do
    docker!([
      "exec",
      "-w",
      "/build/#{app_name}/_build/prod/rel/#{release}",
      container,
      "sh",
      "-c",
      "zip -r /build/function.zip ."
    ])
  end

  defp download_zip!(container, output) do
    File.mkdir_p!(Path.dirname(output))
    docker!(["cp", "#{container}:/build/function.zip", output])
  end

  defp ensure_executable!(bin) do
    unless System.find_executable(bin) do
      Mix.raise("#{bin} not found on PATH, but is required by mix aws_lambda.build")
    end
  end

  defp docker!(args), do: run_cmd!("docker", args)
  defp docker(args), do: run_cmd("docker", args)
  defp tar!(args), do: run_cmd!("tar", args)

  defp run_cmd!(bin, args) do
    case run_cmd(bin, args) do
      :ok -> :ok
      {:error, status} -> Mix.raise("#{bin} #{Enum.join(args, " ")} exited with status #{status}")
    end
  end

  defp run_cmd(bin, args) do
    Mix.shell().info("$ #{bin} #{Enum.join(args, " ")}")

    case System.cmd(bin, args, into: IO.stream(:stdio, :line), stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {_output, status} -> {:error, status}
    end
  end
end
