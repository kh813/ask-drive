defmodule AskDriveWeb.GettextJaTest do
  @moduledoc """
  Every message the screens show has its Japanese: none left untranslated or still marked
  fuzzy by `mix gettext.extract --merge` (fuzzy ones aren't used, so the English shows).
  """
  use ExUnit.Case, async: true

  alias Expo.{Message, PO}

  @dir "priv/gettext"

  for domain <- ["default", "errors"] do
    test "#{domain}.po: every message in the template is translated, none fuzzy" do
      domain = unquote(domain)
      po = PO.parse_file!(Path.join(@dir, "ja/LC_MESSAGES/#{domain}.po"))
      pot = PO.parse_file!(Path.join(@dir, "#{domain}.pot"))

      translated = Map.new(po.messages, &{Message.key(&1), &1})

      missing = for m <- pot.messages, not Map.has_key?(translated, Message.key(m)), do: id(m)
      assert missing == [], "not in ja/#{domain}.po (run mix gettext.extract --merge)"

      fuzzy = for m <- po.messages, Message.has_flag?(m, "fuzzy"), do: id(m)
      assert fuzzy == [], "still fuzzy in ja/#{domain}.po"

      empty = for m <- po.messages, untranslated?(m), do: id(m)
      assert empty == [], "untranslated in ja/#{domain}.po"
    end
  end

  defp untranslated?(%Message.Singular{msgstr: msgstr}), do: blank?(msgstr)

  defp untranslated?(%Message.Plural{msgstr: msgstr}),
    do: msgstr == %{} or Enum.any?(Map.values(msgstr), &blank?/1)

  defp blank?(iodata), do: IO.iodata_to_binary(iodata) |> String.trim() == ""

  defp id(message), do: message |> Message.key() |> inspect()
end
