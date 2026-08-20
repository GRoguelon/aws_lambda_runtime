defmodule Mix.Tasks.AwsLambda.BuildTest do
  use ExUnit.Case, async: true

  @moduletag skip:
               (is_nil(System.find_executable("docker")) or
                  is_nil(System.find_executable("tar"))) &&
                 "docker and tar are required to exercise mix aws_lambda.build"

  test "raises when the Erlang/Elixir versions are missing" do
    assert_raise Mix.Error, ~r/expected an Erlang version and an Elixir version/, fn ->
      Mix.Tasks.AwsLambda.Build.run([])
    end
  end

  test "raises when the builder image can't be pulled" do
    assert_raise Mix.Error, ~r/no builder image found/, fn ->
      Mix.Tasks.AwsLambda.Build.run([
        "0.0.0-does-not-exist",
        "0.0.0-does-not-exist",
        "--release",
        "unused"
      ])
    end
  end
end
