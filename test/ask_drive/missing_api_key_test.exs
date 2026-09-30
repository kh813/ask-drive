defmodule AskDrive.MissingApiKeyTest do
  @moduledoc "A provider chosen before its API key is issued (spec F-343)."
  use AskDriveWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias AskDrive.{LLM, Repo, Settings}

  test "the first boot works with Gemini chosen and no key (initial setup left it blank)" do
    System.put_env("ASK_DRIVE_LLM_PROVIDER", "gemini")
    System.put_env("ASK_DRIVE_EMBED_PROVIDER", "gemini")

    on_exit(fn ->
      System.delete_env("ASK_DRIVE_LLM_PROVIDER")
      System.delete_env("ASK_DRIVE_EMBED_PROVIDER")
    end)

    Repo.delete_all(AskDrive.Settings.Setting)
    setting = Settings.get_setting!()

    assert LLM.generation_provider(setting) == "gemini"
    assert LLM.missing_api_key(:embedding, setting) == "Google Gemini API"
    assert LLM.missing_api_key(:generation, setting) == "Google Gemini API"
  end

  test "the admin screen can pick Gemini without a key, and says the key is missing", %{
    conn: conn
  } do
    System.put_env("ASK_DRIVE_DISABLE_AUTH", "true")
    on_exit(fn -> System.delete_env("ASK_DRIVE_DISABLE_AUTH") end)

    assert {:ok, _} =
             Settings.update_setting(Settings.get_setting!(), %{
               llm_provider: "gemini",
               embed_provider: "gemini",
               embed_model: "gemini-embedding-001",
               embedding_dim: 768
             })

    {:ok, view, _html} = live(conn, ~p"/it-support/admin")
    assert has_element?(view, "#missing-api-key", "埋め込み（Google Gemini API）の API キーがない")

    {:ok, _} = Settings.update_setting(Settings.get_setting!(), %{gemini_api_key: "AIza-test"})
    {:ok, view, _html} = live(conn, ~p"/it-support/admin")
    refute has_element?(view, "#missing-api-key")
  end
end
