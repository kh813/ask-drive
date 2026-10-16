defmodule AskDrive.AssetsAliasTest do
  use ExUnit.Case, async: true

  # The colocated hooks (<script :type={Phoenix.LiveView.ColocatedHook}>, e.g. the chat's
  # .ChatScroll) reach the JS bundle only from compiled code. A release runs
  # `mix assets.deploy` before `mix release` compiles, so without compiling first it bundled
  # the previous build's hooks: v0.1.33 shipped without the chat's auto-scroll.
  test "assets.deploy compiles before bundling the JS" do
    steps = Mix.Project.config()[:aliases][:"assets.deploy"]
    compile = Enum.find_index(steps, &(&1 == "compile"))
    esbuild = Enum.find_index(steps, &String.starts_with?(&1, "esbuild"))

    assert compile && esbuild && compile < esbuild
  end
end
