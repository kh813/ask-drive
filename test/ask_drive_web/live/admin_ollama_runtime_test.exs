defmodule AskDriveWeb.AdminOllamaRuntimeTest do
  @moduledoc """
  The platform settings' Ollama card (spec F-837): installed or not, running or not, which
  desks need it, and installing it from the screen.
  """
  use AskDriveWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias AskDrive.LLM.OllamaInstaller

  setup %{conn: conn} do
    on_exit(fn ->
      Application.delete_env(:ask_drive, :ollama_install_command)
      :ok = Supervisor.terminate_child(AskDrive.Supervisor, OllamaInstaller)
      {:ok, _} = Supervisor.restart_child(AskDrive.Supervisor, OllamaInstaller)
    end)

    admin = user_fixture(admin_eligible: true)
    %{conn: log_in_admin(conn, admin), admin: admin}
  end

  test "shows the state, and which desks need Ollama", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin?tab=settings")

    assert has_element?(view, "#ollama-runtime #ollama-installed")
    assert has_element?(view, "#ollama-runtime #ollama-running")
    # the test desk embeds with Ollama (the default)
    assert has_element?(view, "#ollama-needed li", "IT-Support")
    # without app.sh (tests) it can't be installed from here
    refute has_element?(view, "#install-ollama-btn")
  end

  test "installs from the screen and shows the output", %{conn: conn, admin: admin} do
    Application.put_env(
      :ask_drive,
      :ollama_install_command,
      {"/bin/sh", ["-c", "echo 'Ollama をダウンロードしています'; echo 'インストールしました'"]}
    )

    Phoenix.PubSub.subscribe(AskDrive.PubSub, OllamaInstaller.topic())
    {:ok, view, _html} = live(conn, ~p"/admin?tab=settings")

    view |> element("#install-ollama-btn") |> render_click()
    assert_receive {:ollama_install, %{status: :done, by: by}}, 5_000
    assert by == admin.email

    _ = :sys.get_state(view.pid)
    assert has_element?(view, "#ollama-install-status", "インストールしました")
  end
end
