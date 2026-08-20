defmodule Mix.Tasks.AwsLambda.Build do
  use Mix.Task

  @shortdoc "Packages a Lambda release into a deployable zip using the Elixir builder image"

  @moduledoc """
  Builds this project's Lambda release inside the `layers/elixir` Docker image
  and downloads the resulting deployment zip.

  Run from a function app (e.g. `hello_function`) that depends on
  `:aws_lambda_runtime` as a sibling path dependency:

      mix aws_lambda.build

  This assumes the monorepo layout:

      <root>/
        layers/elixir/Dockerfile
        aws_lambda_runtime/
        hello_function/        <- current directory when the task runs

  ## What it does

    1. Builds the `final-elixir` target of `layers/elixir/Dockerfile` into a
       local image.
    2. Creates a container from that image.
    3. Copies this app's source and the `aws_lambda_runtime` source into it.
    4. Runs `mix deps.get` and `mix release` inside the container.
    5. Zips the release directory inside the container.
    6. Copies the zip back out to the host.
    7. Removes the container.

  ## Options

    * `--release` / `-r` - name of the release to build. Defaults to the
      first release declared in `mix.exs`.
    * `--output` / `-o` - where to write the zip on the host. Defaults to
      `_build/<release>.zip`.
    * `--root` - path to the monorepo root (parent of `layers/` and this
      app). Defaults to `..` relative to the current directory.
    * `--image` - tag for the builder image. Defaults to
      `aws-lambda-elixir-builder:latest`.
    * `--platform` - Docker platform to build/run for. Defaults to
      `linux/arm64`.
  """

  ## Module attributes

  @default_image "aws-lambda-elixir-builder:latest"
  @default_platform "linux/arm64"

  ## Public functions

  @doc "Entry point invoked by `mix aws_lambda.build`. See the moduledoc for details."
  @impl Mix.Task
  def run(args) do
    {opts, _args} =
      OptionParser.parse!(args,
        strict: [
          release: :string,
          output: :string,
          root: :string,
          image: :string,
          platform: :string
        ],
        aliases: [r: :release, o: :output]
      )

    ensure_executable!("docker")
    ensure_executable!("tar")

    app_root = File.cwd!()
    app_name = Path.basename(app_root)
    root = Path.expand(opts[:root] || "..", app_root)
    runtime_root = Path.join(root, "aws_lambda_runtime")
    dockerfile_dir = Path.join([root, "layers", "elixir"])

    unless File.dir?(runtime_root) do
      Mix.raise("expected aws_lambda_runtime source at #{runtime_root}, but it doesn't exist")
    end

    unless File.exists?(Path.join(dockerfile_dir, "Dockerfile")) do
      Mix.raise("expected a Dockerfile at #{dockerfile_dir}, but it doesn't exist")
    end

    release = opts[:release] || default_release()
    image = opts[:image] || @default_image
    platform = opts[:platform] || @default_platform
    output = Path.expand(opts[:output] || Path.join("_build", "#{release}.zip"), app_root)

    container = "#{app_name}-lambda-build-#{System.unique_integer([:positive])}"

    Mix.shell().info("==> Building builder image (#{image})")
    build_image!(image, platform, dockerfile_dir)

    Mix.shell().info("==> Creating container #{container}")
    create_container!(container, image, platform)

    try do
      Mix.shell().info("==> Copying source into container")
      copy_source!(container, root, [runtime_root, app_root])

      Mix.shell().info("==> Packaging release (mix release #{release})")
      package_release!(container, app_name, release)

      Mix.shell().info("==> Zipping build")
      zip_release!(container, app_name, release)

      Mix.shell().info("==> Downloading build")
      download_zip!(container, output)

      Mix.shell().info([:green, "==> wrote #{output}"])
    after
      Mix.shell().info("==> Removing container")
      docker(["rm", "-f", container])
    end
  end

  ## Private functions

  defp default_release do
    case Mix.Project.config()[:releases] do
      [{name, _config} | _rest] -> to_string(name)
      _ -> Mix.raise("no releases declared in mix.exs and no --release given")
    end
  end

  defp build_image!(image, platform, dockerfile_dir) do
    docker!([
      "build",
      "--platform",
      platform,
      "--target",
      "final-elixir",
      "-t",
      image,
      dockerfile_dir
    ])
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

  # Tars the given source directories (relative to `root`, so the container
  # gets the same sibling layout as the host) on the host, excluding local
  # build artifacts, then uploads and extracts the tar inside the container.
  # This avoids copying host-compiled (non-Linux) _build/deps artifacts into
  # the container, and avoids the multi-step edge cases of `docker cp` when
  # copying several directories at once.
  defp copy_source!(container, root, dirs) do
    tar_path = Path.join(System.tmp_dir!(), "#{container}.tar")

    entries = Enum.map(dirs, &Path.relative_to(&1, root))

    tar!(
      [
        "--exclude=_build",
        "--exclude=deps",
        "--exclude=.git",
        "-cf",
        tar_path,
        "-C",
        root
      ] ++ entries
    )

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
      "mix deps.get && mix release #{release}"
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
