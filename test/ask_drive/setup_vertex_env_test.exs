defmodule AskDrive.SetupVertexEnvTest do
  @moduledoc """
  Google Agent Platform chosen in the initial setup (F-835): its key, project and location
  from `.env.prod` are the first settings; a mistyped project is left for the settings screen
  instead of failing the settings row.
  """
  use AskDrive.DataCase, async: false

  alias AskDrive.{LLM, Repo, Settings}

  setup do
    Repo.delete_all(Settings.Setting)

    on_exit(fn ->
      for name <-
            ~w(ASK_DRIVE_LLM_PROVIDER ASK_DRIVE_LLM_MODEL VERTEX_API_KEY VERTEX_PROJECT VERTEX_LOCATION),
          do: System.delete_env(name)
    end)
  end

  test "the provider, key, project and location become the first settings" do
    System.put_env("ASK_DRIVE_LLM_PROVIDER", "vertex")
    System.put_env("ASK_DRIVE_LLM_MODEL", "gemini-2.5-flash")
    System.put_env("VERTEX_API_KEY", "vertex-key")
    System.put_env("VERTEX_PROJECT", "my-project-123")
    System.put_env("VERTEX_LOCATION", "Asia-Northeast1")

    setting = Settings.get_setting!()
    assert setting.llm_provider == "vertex"
    assert setting.vertex_api_key == "vertex-key"
    assert setting.vertex_project == "my-project-123"
    assert setting.vertex_location == "asia-northeast1"
    assert LLM.missing_api_key(:generation, setting) == nil
  end

  test "without a project: the global endpoint, with the key alone" do
    System.put_env("ASK_DRIVE_LLM_PROVIDER", "vertex")
    System.put_env("VERTEX_API_KEY", "vertex-key")
    System.put_env("VERTEX_PROJECT", "")
    System.put_env("VERTEX_LOCATION", "")

    setting = Settings.get_setting!()
    assert setting.vertex_project in [nil, ""]
    assert LLM.quota_key(setting) |> elem(0) == "vertex"
  end

  test "a mistyped project doesn't stop the settings from being made" do
    System.put_env("ASK_DRIVE_LLM_PROVIDER", "vertex")
    System.put_env("VERTEX_PROJECT", "My Project")

    assert %Settings.Setting{vertex_project: nil} = Settings.get_setting!()
  end
end
