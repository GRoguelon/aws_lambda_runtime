defmodule Mix.Tasks.AwsLambda.BuildTest do
  # Changes DOCKER_HOST, which every docker command reads.
  use ExUnit.Case, async: false

  @moduletag skip:
               (is_nil(System.find_executable("docker")) or
                  is_nil(System.find_executable("tar"))) &&
                 "docker and tar are required to exercise mix aws_lambda.build"

  @docker_running System.find_executable("docker") &&
                    match?({_, 0}, System.cmd("docker", ["info"], stderr_to_stdout: true))

  test "raises when the Erlang/Elixir versions are missing" do
    assert_raise Mix.Error, ~r/expected an Erlang version and an Elixir version/, fn ->
      Mix.Tasks.AwsLambda.Build.run([])
    end
  end

  test "raises when the Docker daemon can't be reached" do
    previous = System.get_env("DOCKER_HOST")
    System.put_env("DOCKER_HOST", "unix:///nonexistent/docker.sock")

    on_exit(fn ->
      if previous,
        do: System.put_env("DOCKER_HOST", previous),
        else: System.delete_env("DOCKER_HOST")
    end)

    assert_raise Mix.Error, ~r/cannot reach the Docker daemon, is Docker running\?/, fn ->
      Mix.Tasks.AwsLambda.Build.run(["29.1.2", "1.20.5", "--release", "unused"])
    end
  end

  @tag skip: !@docker_running && "requires a running Docker daemon"
  test "raises when the builder image can't be pulled" do
    assert_raise Mix.Error, ~r/could not pull the builder image/, fn ->
      Mix.Tasks.AwsLambda.Build.run([
        "0.0.0-does-not-exist",
        "0.0.0-does-not-exist",
        "--release",
        "unused"
      ])
    end
  end
end
