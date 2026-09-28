defmodule AskDrive.Snippet do
  @moduledoc """
  Builds the part of a chunk shown in chat, with the question's terms highlighted.

  Tier 2 used to print the whole chunk (hundreds of characters of raw PDF text) with no hint
  of where the question actually matched. This picks the window with the most term hits and
  splits it into plain / highlighted segments for the template to render.

  Matching ignores case and whitespace inside a term, so the question's "USBメモリ" also
  marks "USB メモリ" as it appears in the document.
  """

  alias AskDrive.Ingest.TextCleaner
  alias AskDrive.Retrieval

  @window 160

  @doc """
  Returns `%{before?: bool, segments: [{:text | :hit, String.t()}], after?: bool, hits: n}`
  for the best window of `content` around the question's terms.
  """
  def build(content, question, opts \\ []) do
    window = Keyword.get(opts, :window, @window)
    text = display_text(content)
    ranges = hit_ranges(text, question)

    if ranges == [] do
      {slice, after?} = take_prefix(text, window)
      %{before?: false, segments: [{:text, slice}], after?: after?, hits: 0}
    else
      {from, to} = best_window(ranges, String.length(text), window)
      inside = Enum.filter(ranges, fn {s, e} -> s >= from and e <= to end)

      %{
        before?: from > 0,
        segments: segments(text, from, to, inside),
        after?: to < String.length(text),
        hits: length(inside)
      }
    end
  end

  @doc "The whole cleaned chunk as segments, every hit highlighted (for 全文を表示)."
  def full(content, question) do
    text = display_text(content)
    segments(text, 0, String.length(text), hit_ranges(text, question))
  end

  # The chunker prefixes each chunk with "[文書: name]" for embedding context; the chat
  # card already shows the document name, so drop it along with the layout debris.
  defp display_text(content) do
    (content || "")
    |> String.replace(~r/^\s*\[文書:[^\]]*\]\s*/u, "")
    |> TextCleaner.clean()
  end

  # Character ranges {start, end_exclusive} of term matches, longest terms first so
  # "USBメモリ" wins over "USB" where both match; overlaps are dropped.
  defp hit_ranges(text, question) do
    question
    |> Retrieval.extract_terms()
    |> Enum.sort_by(&(-String.length(&1)))
    |> Enum.flat_map(fn term -> matches(text, term) end)
    |> Enum.reduce([], fn {s, e} = r, acc ->
      if Enum.any?(acc, fn {s2, e2} -> s < e2 and s2 < e end), do: acc, else: [r | acc]
    end)
    |> Enum.sort()
  end

  defp matches(text, term) do
    pattern =
      term
      |> String.graphemes()
      |> Enum.map(&Regex.escape/1)
      |> Enum.join("[\\s\\x{3000}]*")

    case Regex.compile(pattern, "iu") do
      {:ok, regex} ->
        regex
        |> Regex.scan(text, return: :index)
        |> Enum.map(fn [{byte_start, byte_len}] ->
          start = text |> binary_part(0, byte_start) |> String.length()
          len = text |> binary_part(byte_start, byte_len) |> String.length()
          {start, start + len}
        end)

      _ ->
        []
    end
  end

  # The window (of `window` chars) containing the most hits, centred on its hits.
  defp best_window(ranges, text_len, window) do
    {best_s, _} =
      ranges
      |> Enum.map(fn {s, _e} ->
        {s, Enum.count(ranges, fn {s2, e2} -> s2 >= s and e2 <= s + window end)}
      end)
      |> Enum.max_by(fn {_s, count} -> count end)

    from = max(0, best_s - div(window, 3))
    to = min(text_len, from + window)
    {max(0, min(from, to - window)), to}
  end

  defp segments(text, from, to, ranges) do
    {segs, cursor} =
      Enum.reduce(ranges, {[], from}, fn {s, e}, {acc, cur} ->
        acc = if s > cur, do: [{:text, String.slice(text, cur, s - cur)} | acc], else: acc
        {[{:hit, String.slice(text, s, e - s)} | acc], e}
      end)

    segs =
      if to > cursor, do: [{:text, String.slice(text, cursor, to - cursor)} | segs], else: segs

    Enum.reverse(segs)
  end

  defp take_prefix(text, window) do
    if String.length(text) > window,
      do: {String.slice(text, 0, window), true},
      else: {text, false}
  end
end
