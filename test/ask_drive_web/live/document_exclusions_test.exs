defmodule AskDriveWeb.DocumentExclusionsTest do
  @moduledoc "Leaving files and folders out of the nightly batch from the documents tab (F-358)."
  use AskDriveWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias AskDrive.Documents.{Document, Exclusion}
  alias AskDrive.Repo

  setup %{conn: conn} do
    admin = user_fixture(admin_eligible: true)

    doc =
      %Document{}
      |> Document.changeset(%{
        drive_file_id: "f-old",
        name: "旧手順.pdf",
        mime_type: "application/pdf",
        status: "indexed",
        path: "/共有/旧版/旧手順.pdf",
        folder_ids: ["folder-old"]
      })
      |> Repo.insert!()

    %{conn: conn |> log_in_admin(admin) |> log_in_app_admin(admin), doc: doc, admin: admin}
  end

  test "leaves a file out from its row, then brings it back", %{
    conn: conn,
    doc: doc,
    admin: admin
  } do
    {:ok, view, _html} = live(conn, ~p"/it-support/admin?tab=documents")
    assert has_element?(view, "#exclusions #no-exclusions")

    view |> element("#exclude-file-#{doc.id}") |> render_click()

    ex = Repo.get_by!(Exclusion, drive_id: "f-old")
    assert ex.excluded_by == admin.email
    assert has_element?(view, "#exclusion-#{ex.id}")
    assert Repo.get_by!(Document, drive_file_id: "f-old").status == "skipped"

    view |> element("#remove-exclusion-#{ex.id}") |> render_click()
    refute has_element?(view, "#exclusion-#{ex.id}")
    assert Repo.get_by!(Document, drive_file_id: "f-old").status == "pending"
  end

  test "leaves the folder a document sits in out", %{conn: conn, doc: doc} do
    {:ok, view, _html} = live(conn, ~p"/it-support/admin?tab=documents")

    view |> element("#exclude-folder-#{doc.id}-folder-old") |> render_click()

    ex = Repo.get_by!(Exclusion, drive_id: "folder-old")
    assert ex.kind == "folder" and ex.path == "/共有/旧版"
    assert has_element?(view, "#exclusion-#{ex.id}")
    refute has_element?(view, "#document-#{doc.id}")
  end
end
