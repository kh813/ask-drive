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
    refute hidden?(view, "connection-ollama")

    for p <- ~w(lmstudio gemini openai anthropic), do: assert(hidden?(view, "connection-#{p}"))

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
    refute hidden?(view, "connection-gemini")
    assert hidden?(view, "connection-ollama")
    assert hidden?(view, "connection-lmstudio")
    assert hidden?(view, "connection-openai")
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
    refute hidden?(view, "connection-ollama")
    refute hidden?(view, "connection-gemini")

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
end
