defmodule AWS.Lambda.Runtime.MixProject do
  use Mix.Project

  @source_url "https://github.com/GRoguelon/aws_lambda_runtime"
  @version "0.1.1"

  def project do
    [
      app: :aws_lambda_runtime,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      package: package(),
      name: "AWS Lambda Runtime",
      description:
        "A dependency-free AWS Lambda custom runtime for Elixir" <>
          ", built on :inets/:httpc and the OTP-bundled JSON module" <>
          ", meant to run on a Lambda layer providing OTP.",
      source_url: @source_url,
      docs: docs()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :inets, :ssl],
      mod: {AWS.Lambda.Runtime.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp package do
    [
      name: :aws_lambda_runtime,
      files: ~w[lib priv .formatter.exs mix.exs README* CHANGELOG* LICENSE*],
      maintainers: ["Geoffrey Roguelon"],
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "https://aws-lambda-runtime.hexdocs.pm/changelog.html"
      }
    ]
  end

  defp docs do
    [
      formatters: ["html"],
      main: "readme",
      extras: ["README.md", "CHANGELOG.md"],
      source_ref: "v#{@version}",
      source_url: @source_url,
      skip_undefined_reference_warnings_on: ["CHANGELOG.md"]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      ## Dev
      {:ex_doc, "~> 0.34", only: :dev, runtime: false, warn_if_outdated: true}
    ]
  end
end
