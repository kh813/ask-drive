defmodule AskDriveWeb.AdminOllamaModelsTest do
  use AskDriveWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias AskDrive.{Settings, StubOllama}

  setup do
    System.put_env("ASK_DRIVE_DISABLE_AUTH", "true")
    on_exit(fn -> System.delete_env("ASK_DRIVE_DISABLE_AUTH") end)

    {server, url} = StubOllama.start!(self())
    # pulls finished by earlier tests would show instead of this test's state
    AskDrive.LLM.OllamaModels.reset_pulls()
    on_exit(fn -> Process.exit(server, :normal) end)

    {:ok, setting} =
      Settings.update_setting(Settings.get_setting!(), %{
        ollama_host: url,
        llm_provider: "ollama",
        embed_provider: "ollama",
        chat_summary_model: "qwen3:4b-instruct-2507-q4_K_M"
      })

    StubOllama.put_installed(["#{setting.embed_model}:latest", setting.batch_model])
    %{setting: setting}
  end

  test "settings show required models' state and can pull a model by name", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/admin?tab=settings")

    assert html =~ "ローカルモデル（Ollama）"
    assert has_element?(view, ~s(tr[data-model="qwen3:4b-instruct-2507-q4_K_M"]), "未取得")

    view
    |> form("#pull-model-form", %{"model" => "qwen3:4b-instruct-2507-q4_K_M"})
    |> render_submit()

    assert_receive {:stub_pull, "qwen3:4b-instruct-2507-q4_K_M"}, 2_000

    # once the pull finishes the row turns to 取得済み
    Process.sleep(300)
    assert has_element?(view, ~s(tr[data-model="qwen3:4b-instruct-2507-q4_K_M"]), "取得済み")
  end
end
