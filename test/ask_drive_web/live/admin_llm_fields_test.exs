defmodule AskDriveWeb.AdminLlmFieldsTest do
  @moduledoc """
  A desk's AI settings show only the chosen side's fields (spec F-833): a local LLM's
  (Ollama / LM Studio) or a cloud API's (Gemini / OpenAI / Claude), for the nightly batch and
  for the chat summary alike. The connection section lists only the providers in use.
  """
  use AskDriveWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias AskDrive.Settings

  setup do
    System.put_env("ASK_DRIVE_DISABLE_AUTH", "true")
    on_exit(fn -> System.delete_env("ASK_DRIVE_DISABLE_AUTH") end)

    {:ok, _} =
      Settings.update_setting(Settings.get_setting!(), %{
        batch_llm_mode: "local",
        llm_provider: "ollama",
        embed_provider: "ollama",
        chat_summary_provider: "",
        chat_summary_model: ""
      })

    :ok
  end

  defp hidden?(view, id), do: has_element?(view, "##{id}.hidden")

  defp open(conn) do
    {:ok, view, _html} = live(conn, "/it-support/admin?tab=settings")
    view
  end

  test "local: only the local LLM's fields and Ollama's connection", %{conn: conn} do
    view = open(conn)

    refute hidden?(view, "batch-local-fields")
    assert hidden?(view, "batch-cloud-fields")
    # the provider's connection right under the nightly batch's choice
    assert has_element?(view, "#batch-llm #connection-ollama")

    for p <- ~w(lmstudio gemini vertex openai anthropic),
        do: refute(has_element?(view, "#connection-#{p}"))

    # 夜間バッチと同じ: no provider of its own to pick
    refute has_element?(view, "select[name='setting[chat_summary_provider]']")
  end

  test "choosing the cloud API shows its fields and hides the local ones", %{conn: conn} do
    view = open(conn)

    view
    |> form("#settings-form", %{
      "setting" => %{
        "batch_llm_mode" => "cloud",
        "cloud_llm_provider" => "gemini",
        "embed_provider" => "gemini"
      }
    })
    |> render_change()

    assert hidden?(view, "batch-local-fields")
    refute hidden?(view, "batch-cloud-fields")
    # Gemini's fields under the batch, once (the embedding uses it too), and no local ones
    assert has_element?(view, "#batch-llm #connection-gemini")

    assert [_] =
             view
             |> render()
             |> LazyHTML.from_fragment()
             |> LazyHTML.query("#connection-gemini")
             |> Enum.to_list()

    refute has_element?(view, "#connection-ollama")
    refute has_element?(view, "#connection-lmstudio")
    refute has_element?(view, "#connection-openai")
  end

  test "the chat summary's own side lists only that side's providers", %{conn: conn} do
    view = open(conn)

    view
    |> form("#settings-form", %{"setting" => %{"chat_summary_mode" => "cloud"}})
    |> render_change()

    assert has_element?(
             view,
             "select[name='setting[chat_summary_provider]'] option[value='gemini']"
           )

    refute has_element?(
             view,
             "select[name='setting[chat_summary_provider]'] option[value='ollama']"
           )

    # the batch stays local, so Ollama is still needed; the summary's Gemini is too
    assert has_element?(view, "#batch-llm #connection-ollama")
    assert has_element?(view, "#chat-summary-llm #connection-gemini")

    view
    |> form("#settings-form", %{
      "setting" => %{
        "chat_summary_mode" => "cloud",
        "chat_summary_provider" => "openai",
        "chat_summary_model" => "gpt-test"
      }
    })
    |> render_submit()

    setting = Settings.get_setting!()
    assert setting.chat_summary_provider == "openai"
    assert setting.chat_summary_model == "gpt-test"
    # the batch's local settings were kept
    assert setting.llm_provider == "ollama"
    assert has_element?(view, "#chat-summary-mode option[value='cloud'][selected]")
  end

  test "a chat summary on the batch's provider doesn't repeat its connection fields", %{
    conn: conn
  } do
    view = open(conn)

    view
    |> form("#settings-form", %{"setting" => %{"chat_summary_mode" => "local"}})
    |> render_change()

    assert has_element?(view, "#batch-llm #connection-ollama")
    refute has_element?(view, "#chat-summary-llm #connection-ollama")
  end

  test "夜間バッチと同じ is saved as no provider of its own", %{conn: conn} do
    {:ok, _} =
      Settings.update_setting(Settings.get_setting!(), %{
        chat_summary_provider: "gemini",
        chat_summary_model: "gemini-test"
      })

    view = open(conn)
    assert has_element?(view, "#chat-summary-mode option[value='cloud'][selected]")

    view
    |> form("#settings-form", %{"setting" => %{"chat_summary_mode" => "same"}})
    |> render_submit()

    assert Settings.get_setting!().chat_summary_provider in [nil, ""]
  end

  test "a summary on the batch's cloud provider needs no model name of its own" do
    {:ok, setting} =
      Settings.update_setting(Settings.get_setting!(), %{
        batch_llm_mode: "cloud",
        cloud_llm_provider: "gemini",
        cloud_llm_model: "gemini-test"
      })

    assert {:ok, _} =
             Settings.update_setting(setting, %{
               chat_summary_provider: "gemini",
               chat_summary_model: ""
             })
  end

  describe "the cloud API's model pull-down (F-834)" do
    setup do
      {server, url} = AskDrive.StubGemini.start!(self())
      on_exit(fn -> Process.exit(server, :normal) end)

      AskDrive.StubGemini.set(:models, [
        %{
          "name" => "models/gemini-2.5-flash",
          "displayName" => "Gemini 2.5 Flash",
          "supportedGenerationMethods" => ["generateContent"]
        },
        %{
          "name" => "models/gemini-embedding-001",
          "supportedGenerationMethods" => ["embedContent"]
        }
      ])

      {:ok, _} =
        Settings.update_setting(Settings.get_setting!(), %{
          batch_llm_mode: "cloud",
          cloud_llm_provider: "gemini",
          cloud_llm_model: "gemini-old",
          gemini_base_url: url,
          gemini_api_key: "k-#{System.unique_integer([:positive])}"
        })

      :ok
    end

    test "lists the provider's generation models, keeping the saved one", %{conn: conn} do
      view = open(conn)
      _ = render_async(view)

      select = "#cloud-llm-model-field select[name='setting[cloud_llm_model]']"
      assert has_element?(view, "#{select} option[value='gemini-2.5-flash']")
      refute has_element?(view, "#{select} option[value='gemini-embedding-001']")
      assert has_element?(view, "#{select} option[value='gemini-old'][selected]")

      view |> element("#refresh-cloud-models") |> render_click()
      _ = render_async(view)
      assert_received {:stub_gemini, "models", _}
      assert_received {:stub_gemini, "models", _}

      view
      |> form("#settings-form", %{"setting" => %{"cloud_llm_model" => "gemini-2.5-flash"}})
      |> render_submit()

      assert Settings.get_setting!().cloud_llm_model == "gemini-2.5-flash"
    end

    test "a key that may not list models gets the manual's models as suggestions", %{
      conn: conn
    } do
      AskDrive.StubGemini.set(:models_blocked, true)

      view = open(conn)
      _ = render_async(view)

      input = "#cloud-llm-model-field input[name='setting[cloud_llm_model]']"

      assert has_element?(
               view,
               "#{input}[list='cloud-llm-model-suggestions'][value='gemini-old']"
             )

      assert has_element?(view, "#cloud-llm-model-suggestions option[value='gemini-2.5-flash']")
      assert has_element?(view, "#cloud-models-status")

      # a name that isn't suggested can still be saved
      view
      |> form("#settings-form", %{"setting" => %{"cloud_llm_model" => "gemini-next"}})
      |> render_submit()

      assert Settings.get_setting!().cloud_llm_model == "gemini-next"
    end

    test "Agent Platform: its connection fields, and the manual's models as suggestions", %{
      conn: conn
    } do
      {:ok, _} =
        Settings.update_setting(Settings.get_setting!(), %{
          cloud_llm_provider: "vertex",
          cloud_llm_model: "gemini-2.5-flash",
          vertex_api_key: "vk-1234"
        })

      view = open(conn)
      _ = render_async(view)

      assert has_element?(view, "#batch-llm #connection-vertex")
      refute has_element?(view, "#connection-gemini")
      assert has_element?(view, "#cloud-llm-model-suggestions option[value='gemini-2.5-pro']")
      # nothing is asked for a list
      refute_received {:stub_gemini, "models", _}

      view
      |> form("#settings-form", %{
        "setting" => %{"vertex_project" => "my-proj-1", "vertex_location" => "asia-northeast1"}
      })
      |> render_submit()

      setting = Settings.get_setting!()
      assert {setting.vertex_project, setting.vertex_location} == {"my-proj-1", "asia-northeast1"}
      assert AskDrive.LLM.api_key("vertex", setting) == "vk-1234"
    end

    test "without an API key the name is typed by hand", %{conn: conn} do
      # no Claude key saved (a blank key field keeps the saved one, so use another provider)
      {:ok, _} =
        Settings.update_setting(Settings.get_setting!(), %{cloud_llm_provider: "anthropic"})

      assert AskDrive.LLM.api_key("anthropic", Settings.get_setting!()) in [nil, ""]

      view = open(conn)
      _ = render_async(view)

      assert has_element?(view, "#cloud-llm-model-field input[name='setting[cloud_llm_model]']")
      assert has_element?(view, "#cloud-models-status")
    end
  end
end
