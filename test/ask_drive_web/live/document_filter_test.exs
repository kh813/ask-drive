defmodule AskDriveWeb.DocumentFilterTest do
  @moduledoc "Filtering the desk's document list (F-1412)."
  use AskDriveWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias AskDrive.Documents.Document
  alias AskDrive.Repo

  setup %{conn: conn} do
    admin = user_fixture(admin_eligible: true)

    docs =
      for {name, mime, status} <- [
            {"手順書.pdf", "application/pdf", "failed"},
            {"README.md", "text/markdown", "pending"}
          ] do
        %Document{}
        |> Document.changeset(%{drive_file_id: name, name: name, mime_type: mime, status: status})
        |> Repo.insert!()
      end

    %{conn: conn |> log_in_admin(admin) |> log_in_app_admin(admin), docs: docs}
  end

  test "narrows the list by name and type, then clears", %{conn: conn, docs: [pdf, md]} do
    {:ok, view, _html} = live(conn, ~p"/it-support/admin?tab=documents")
    assert has_element?(view, "#document-#{pdf.id}")
    assert has_element?(view, "#document-#{md.id}")

    view |> form("#document-filter-form", filter: %{type: ".pdf"}) |> render_change()
    assert has_element?(view, "#document-#{pdf.id}")
    refute has_element?(view, "#document-#{md.id}")

    view |> form("#document-filter-form", filter: %{q: "存在しない"}) |> render_change()
    assert has_element?(view, "#no-matching-documents")

    view |> element("#reset-document-filter-btn") |> render_click()
    assert has_element?(view, "#document-#{pdf.id}")
    assert has_element?(view, "#document-#{md.id}")
  end
end
