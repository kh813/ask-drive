defmodule AskDrive.Ingest.TextCleaner do
  @moduledoc """
  Removes layout debris that `pdftotext -layout` leaves in Japanese PDFs.

  Printed guidelines often carry vertical side tabs ("第1部") and doubled glyphs. Extracted
  line by line they show up as lines like "じ じ", "第第", "部部", or as a lone "第" separated
  from the real text by a wide run of spaces. That debris polluted both the excerpts shown in
  chat and the text that gets embedded.

  Applied when text is extracted and again when an excerpt is displayed, so chunks indexed
  before this existed are shown clean too.
  """

  # Side tabs are kanji/kana ("第", "部", "じ"); limiting the fragment rules to those keeps
  # table cells such as "13:40      17:20" intact.
  @kana_kanji "[\\p{Han}\\x{3041}-\\x{309F}\\x{30A0}-\\x{30FF}]"

  @doc "Cleans extracted text. Idempotent."
  def clean(text) when is_binary(text) do
    text
    |> String.split("\n")
    |> Enum.map(&clean_line/1)
    |> Enum.reject(&debris_line?/1)
    |> Enum.join("\n")
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
  end

  def clean(other), do: other

  defp clean_line(line) do
    line
    # a 1-2 char side-tab fragment, then a wide gap, then the real text: "第      リスクの…"
    |> String.replace(~r/^\s*#{@kana_kanji}{1,2}\s{6,}(?=\S)/u, "")
    # real text, a wide gap, then short fragments to the end: "…これに      第第"
    |> String.replace(~r/(?<=\S)\s{6,}(#{@kana_kanji}{1,3}\s*)+$/u, "")
    # remaining wide gaps (table columns, centring) become a single space
    |> String.replace(~r/[ \t\x{3000}]{3,}/u, " ")
    |> String.trim_trailing()
  end

  # Lines that are only side-tab or doubled-glyph debris: "じ じ", "第第", "部", "に に".
  defp debris_line?(line) do
    compact = String.replace(line, ~r/[\s\x{3000}]/u, "")
    len = String.length(compact)

    cond do
      len == 0 -> false
      len <= 2 -> true
      len <= 4 -> doubled?(compact)
      true -> false
    end
  end

  defp doubled?(s) do
    chars = String.graphemes(s)
    n = length(chars)
    rem(n, 2) == 0 and Enum.take(chars, div(n, 2)) == Enum.drop(chars, div(n, 2))
  end
end
