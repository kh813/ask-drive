defmodule AskDriveWeb.AdminOllamaModelsTest do
  @moduledoc """
  Ollama's models are the platform administrator's (spec F-838): pulled and deleted on the
  platform screen; a desk only chooses among the pulled models and sees whether the ones its
  settings name are pulled.
  """
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

  describe "a desk" do
    test "sees whether its models are pulled, and can't pull one", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/it-support/admin?tab=settings")

      assert has_element?(view, "#ollama-models")
      assert has_element?(view, ~s(tr[data-model="qwen3:4b-instruct-2507-q4_K_M"]), "未取得")
      refute has_element?(view, "#ollama-models button")
      refute has_element?(view, "#pull-model-form")

      # an event sent anyway does nothing on a desk
      render_hook(view, "pull_model", %{"model" => "qwen3:4b-instruct-2507-q4_K_M"})
      refute_receive {:stub_pull, _}, 200
    end

    test "chooses its Ollama models among the pulled ones that can do the job", %{
      conn: conn,
      setting: setting
    } do
      {:ok, view, _html} = live(conn, "/it-support/admin?tab=settings")

      embed = "#settings-form select[name='setting[embed_model]']"
      assert has_element?(view, "#{embed} option[value='#{setting.embed_model}:latest']")
      refute has_element?(view, "#{embed} option[value='#{setting.batch_model}']")

      batch = "#settings-form select[name='setting[batch_model]']"
      assert has_element?(view, "#{batch} option[value='#{setting.batch_model}']")
      refute has_element?(view, "#{batch} option[value='#{setting.embed_model}:latest']")

      # the chat summary's saved model isn't pulled: not offered, and pointed out
      chat = "#settings-form select[name='setting[chat_summary_model]']"
      refute has_element?(view, "#{chat} option[value='qwen3:4b-instruct-2507-q4_K_M']")
      assert render(view) =~ "qwen3:4b-instruct-2507-q4_K_M"
    end

    test "a cloud model name left in the Ollama embedding field must be replaced", %{
      conn: conn,
      setting: setting
    } do
      {:ok, _} =
        Settings.update_setting(setting, %{
          embed_model: "gemini-embedding-001",
          embedding_dim: 768
        })

      {:ok, view, _html} = live(conn, "/it-support/admin?tab=settings")

      embed = "#settings-form select[name='setting[embed_model]']"
      assert has_element?(view, "#{embed}[required]")
      refute has_element?(view, "#{embed} option[value='gemini-embedding-001']")
      assert render(view) =~ "gemini-embedding-001"

      # sent anyway (bypassing the pull-down): refused, nothing saved
      render_submit(view, "save_settings", %{
        "setting" => %{"embed_model" => "gemini-embedding-001"}
      })

      assert render(view) =~ "保存していません"
      assert Settings.get_setting!().embed_model == "gemini-embedding-001"

      # a pulled model: saved, and the dimensions follow the model (bge-m3: 1024)
      view
      |> form("#settings-form", %{
        "setting" => %{"embed_model" => "#{setting.embed_model}:latest"}
      })
      |> render_submit()

      saved = Settings.get_setting!()
      assert saved.embed_model == "#{setting.embed_model}:latest"
      assert saved.embedding_dim == 1024
    end

    test "not in the platform settings, nor on a desk that doesn't use Ollama (F-830)", %{
      conn: conn,
      setting: setting
    } do
      {:ok, _view, html} = live(conn, ~p"/admin?tab=settings")
      refute html =~ ~s(id="ollama-models")

      {:ok, _} =
        Settings.update_setting(setting, %{
          llm_provider: "gemini",
          embed_provider: "gemini",
          chat_summary_provider: "",
          chat_summary_model: ""
        })

      {:ok, _view, html} = live(conn, "/it-support/admin?tab=settings")
      refute html =~ ~s(id="ollama-models")
    end
  end

  describe "the platform administrator" do
    test "sees the pulled models and what the desks miss, and pulls them", %{
      conn: conn,
      setting: setting
    } do
      Phoenix.PubSub.subscribe(AskDrive.PubSub, AskDrive.LLM.OllamaModels.topic())
      {:ok, view, _html} = live(conn, ~p"/admin?tab=settings")

      assert has_element?(
               view,
               ~s(#ollama-model-table tr[data-model="#{setting.embed_model}:latest"]),
               "IT-Support"
             )

      assert has_element?(view, "#ollama-missing-models", "qwen3:4b-instruct-2507-q4_K_M")

      view |> element("#pull-missing-models-btn") |> render_click()
      assert_receive {:stub_pull, "qwen3:4b-instruct-2507-q4_K_M"}, 2_000

      assert_receive {:ollama_pulls, %{"qwen3:4b-instruct-2507-q4_K_M" => %{status: "done"}}},
                     2_000

      _ = :sys.get_state(view.pid)
      refute has_element?(view, "#ollama-missing-models")

      assert has_element?(
               view,
               ~s(#ollama-model-table tr[data-model="qwen3:4b-instruct-2507-q4_K_M"])
             )
    end

    test "pulls a model by name, and deletes one no desk uses", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin?tab=settings")

      view |> form("#pull-model-form", %{"model" => "llama-extra"}) |> render_submit()
      assert_receive {:stub_pull, "llama-extra"}, 2_000

      # wait for the pull to land, then refresh the card
      Process.sleep(200)
      view |> element("#refresh-ollama-btn") |> render_click()
      row = ~s(#ollama-model-table tr[data-model="llama-extra"])
      assert has_element?(view, row)

      view |> element("#{row} button", "削除") |> render_click()
      assert_receive {:stub_delete, "llama-extra"}
      refute has_element?(view, row)
    end

    test "can't delete a model a desk uses", %{conn: conn, setting: setting} do
      {:ok, view, _html} = live(conn, ~p"/admin?tab=settings")

      assert has_element?(
               view,
               ~s(#ollama-model-table tr[data-model="#{setting.embed_model}:latest"] button[disabled])
             )

      render_hook(view, "delete_model", %{"model" => setting.embed_model})
      refute_receive {:stub_delete, _}, 200
    end
  end
end
