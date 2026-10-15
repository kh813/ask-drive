defmodule AskDriveWeb.AdminEnglishTest do
  @moduledoc """
  With English chosen, the admin screens show no Japanese of their own (spec N-701): every
  tab of a desk's admin screen and of the platform admin screen. Names and data that come
  from the database (a desk's name, documents, questions) are the admin's own and may be in
  any language; the test desk's are English.
  """
  use AskDriveWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  @moduletag locale: "en"

  setup do
    System.put_env("ASK_DRIVE_DISABLE_AUTH", "true")
    on_exit(fn -> System.delete_env("ASK_DRIVE_DISABLE_AUTH") end)
    :ok
  end

  # kana and kanji (not `\\p{Han}`, which also takes the middle dot · by script extensions)
  @japanese ~r/[\x{3040}-\x{30FF}\x{3400}-\x{4DBF}\x{4E00}-\x{9FFF}]/u

  # Japanese text nodes and attribute values (labels, placeholders, confirms) of the page
  defp japanese(html) do
    doc = LazyHTML.from_document(html)

    texts =
      doc
      |> LazyHTML.query("body *")
      |> Enum.flat_map(fn node ->
        LazyHTML.attributes(node) |> List.flatten() |> Enum.map(fn {_k, v} -> v end)
      end)

    nodes =
      html
      |> String.replace(~r/<script.*?<\/script>/s, "")
      |> String.split(~r/<[^>]*>/)

    (nodes ++ texts)
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&Regex.match?(@japanese, &1))
    |> Enum.uniq()
  end

  for {path, tabs} <- [
        {"/it-support/admin", ~w(overview questions documents metrics settings)},
        {"/admin", ~w(apps users audit metrics settings update)}
      ],
      tab <- tabs do
    test "#{path} #{tab} tab", %{conn: conn} do
      {:ok, _view, html} = live(conn, "#{unquote(path)}?tab=#{unquote(tab)}")
      assert japanese(html) == []
    end
  end
end
