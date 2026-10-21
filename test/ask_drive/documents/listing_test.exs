defmodule AskDrive.Documents.ListingTest do
  use ExUnit.Case, async: true

  alias AskDrive.Documents.{Document, Listing}

  defp row(name, mime, status, eff \\ nil) do
    %{document: %Document{id: name, name: name, mime_type: mime, status: status}, efficiency: eff}
  end

  defp eff(level, per_kb, tokens \\ 100, bytes \\ 1024) do
    %{score_level: level, tokens_per_kb: per_kb, total_tokens: tokens, raw_size_bytes: bytes}
  end

  setup do
    rows = [
      row("手順書.pdf", "application/pdf", "indexed", eff(:poor, 2.0)),
      row("README.md", "text/markdown", "indexed", eff(:excellent, 250.0)),
      row("規程", "application/vnd.google-apps.document", "indexed", eff(:good, 120.0)),
      row("古い手順書.PDF", "application/pdf", "failed")
    ]

    %{rows: rows}
  end

  defp names(rows), do: Enum.map(rows, & &1.document.name)

  test "file type is the extension, or the Google type" do
    assert Listing.file_type(%Document{name: "a.PDF", mime_type: "application/pdf"}) == ".pdf"

    assert Listing.file_type(%Document{
             name: "規程",
             mime_type: "application/vnd.google-apps.document"
           }) == "Google Docs"

    assert Listing.file_type(%Document{name: "README", mime_type: "text/plain"}) == "—"
  end

  test "filters by name, status, type and grade", %{rows: rows} do
    assert names(Listing.filter(rows, %{"q" => "手順"})) == ["古い手順書.PDF", "手順書.pdf"]
    assert names(Listing.filter(rows, %{"status" => "failed"})) == ["古い手順書.PDF"]

    assert names(Listing.filter(rows, %{"type" => ".pdf", "status" => "indexed"})) ==
             ["手順書.pdf"]

    assert names(Listing.filter(rows, %{"grade" => "poor"})) == ["手順書.pdf"]
    assert names(Listing.filter(rows, %{"grade" => "unrated"})) == ["古い手順書.PDF"]
  end

  test "sorting by efficiency: worst or best first, unrated last either way", %{rows: rows} do
    assert names(Listing.filter(rows, %{"sort" => "efficiency_asc"})) ==
             ["手順書.pdf", "規程", "README.md", "古い手順書.PDF"]

    assert names(Listing.filter(rows, %{"sort" => "efficiency_desc"})) ==
             ["README.md", "規程", "手順書.pdf", "古い手順書.PDF"]
  end

  test "summary of the rows shown", %{rows: rows} do
    summary = rows |> Listing.filter(%{"type" => ".pdf"}) |> Listing.summary()
    assert summary.count == 2
    assert summary.total_tokens == 100
    assert summary.tokens_per_kb == 100.0
    assert summary.by_grade == %{"poor" => 1, "unrated" => 1}
  end
end
