defmodule AskDriveWeb.AdminToolsTest do
  @moduledoc """
  The Install & updates tab's external programs (spec F-839): pdftotext, pandoc, zstd —
  installed or not, installed from the screen when AskDrive can (pandoc), or the commands to
  run on the server; documents skipped for a missing program are read again once it's there.
  """
  use AskDriveWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias AskDrive.{Documents, Repo}
  alias AskDrive.Documents.Document
  alias AskDrive.Runtime.{ToolInstaller, Tools}

  setup %{conn: conn} do
    on_exit(fn ->
      Application.delete_env(:ask_drive, :tool_install_command)
      :ok = Supervisor.terminate_child(AskDrive.Supervisor, ToolInstaller)
      {:ok, _} = Supervisor.restart_child(AskDrive.Supervisor, ToolInstaller)
    end)

    admin = user_fixture(admin_eligible: true)
    %{conn: log_in_admin(conn, admin)}
  end

  test "each program says whether it's installed, and how to install it" do
    tools = Tools.list()
    assert Enum.map(tools, & &1.id) == ~w(pdftotext pandoc zstd)

    pdftotext = Enum.find(tools, &(&1.id == "pdftotext"))
    assert pdftotext.installer == nil

    case Tools.package_manager() do
      :apt -> assert "sudo apt-get install -y poppler-utils" in pdftotext.commands
      :brew -> assert pdftotext.commands == ["brew install poppler"]
      _ -> :ok
    end

    assert Enum.find(tools, &(&1.id == "pandoc")).installer == "pandoc"
  end

  test "the tab is named Install & updates and holds Ollama and the programs", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin?tab=update")

    assert has_element?(view, "#tab-update", "インストールとアップデート")
    assert has_element?(view, "#ollama-runtime")
    assert has_element?(view, "#external-tools #tool-pdftotext")
    assert has_element?(view, "#external-tools #tool-pandoc")

    # no longer under the platform settings
    {:ok, settings, _html} = live(conn, ~p"/admin?tab=settings")
    refute has_element?(settings, "#ollama-runtime")
  end

  test "documents skipped for a missing program go back to the queue once it's installed" do
    {:ok, skipped} =
      %Document{}
      |> Document.changeset(%{
        drive_file_id: "f-#{System.unique_integer([:positive])}",
        name: "a.pdf",
        mime_type: "application/pdf",
        status: "pending"
      })
      |> Repo.insert()

    {:ok, _} =
      Documents.mark_skipped(skipped, Documents.missing_tool_reason("pdftotext") <> " (x)")

    assert Documents.requeue_missing_tool("pandoc") == 0
    assert Documents.requeue_missing_tool("pdftotext") == 1
    assert Repo.get!(Document, skipped.id).status == "pending"
  end
end
