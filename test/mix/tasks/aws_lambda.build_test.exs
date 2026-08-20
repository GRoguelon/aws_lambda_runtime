defmodule Mix.Tasks.AwsLambda.BuildTest do
  use ExUnit.Case, async: true

  @moduletag skip:
               (is_nil(System.find_executable("docker")) or
                  is_nil(System.find_executable("tar"))) &&
                 "docker and tar are required to exercise mix aws_lambda.build"

  setup do
    root =
      Path.join(System.tmp_dir!(), "aws_lambda_build_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)

    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, root: root}
  end

  test "raises when the aws_lambda_runtime source is missing", %{root: root} do
    assert_raise Mix.Error, ~r/expected aws_lambda_runtime source/, fn ->
      Mix.Tasks.AwsLambda.Build.run(["--root", root])
    end
  end

  test "raises when the builder Dockerfile is missing", %{root: root} do
    File.mkdir_p!(Path.join(root, "aws_lambda_runtime"))

    assert_raise Mix.Error, ~r/expected a Dockerfile/, fn ->
      Mix.Tasks.AwsLambda.Build.run(["--root", root])
    end
  end
end
