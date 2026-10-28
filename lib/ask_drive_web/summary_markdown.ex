defmodule AskDriveWeb.SummaryMarkdown do
  @moduledoc """
  The AI summary's Markdown as HTML (spec F-437): what the models write — headings, bullet and
  numbered lists (nested by indentation), **bold**, *italics*, `code`, rules (---) and
  paragraphs. Everything is HTML-escaped first, so the model's text can't add markup of its
  own; links and images aren't made. Text still streaming in renders as far as it has come
  (an unclosed `**` stays as written until it closes).

  `cite` turns each citation "[n]" (already escaped) into what is shown for it.
  """

  @list_item ~r/^(\s*)([-*+]|\d{1,3}[.)])\s+(.*)$/u
  @heading ~r/^\s{0,3}(\#{1,6})\s+(.*?)\s*#*\s*$/u
  @rule ~r/^\s{0,3}([-*_])(\s*\1){2,}\s*$/u

  @doc "`text` as an HTML string."
  def to_html(text, cite \\ fn whole, _n -> whole end) when is_binary(text) do
    text
    |> String.replace("\r\n", "\n")
    |> String.split("\n")
    |> Enum.map(&classify/1)
    |> render(cite)
  end

  defp classify(line) do
    line = String.replace(line, "\t", "    ")

    cond do
      String.trim(line) == "" ->
        :blank

      Regex.match?(@rule, line) ->
        :rule

      match = Regex.run(@heading, line) ->
        [_, hashes, content] = match
        {:heading, String.length(hashes), content}

      match = Regex.run(@list_item, line) ->
        [_, indent, marker, content] = match
        type = if marker in ["-", "*", "+"], do: :ul, else: :ol
        {:item, String.length(indent), type, content}

      true ->
        {:text, indent_of(line), String.trim(line)}
    end
  end

  defp indent_of(line), do: String.length(line) - String.length(String.trim_leading(line))

  # The lines in turn, with the lists open (innermost first: {indent, type}) and whether a
  # paragraph is open.
  defp render(lines, cite) do
    {out, lists, paragraph?} =
      Enum.reduce(lines, {[], [], false}, fn line, {out, lists, paragraph?} ->
        step(line, out, lists, paragraph?, cite)
      end)

    out
    |> close_paragraph(paragraph?)
    |> close_lists(lists)
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end

  defp step(:blank, out, lists, paragraph?, _cite),
    do: {close_paragraph(out, paragraph?), lists, false}

  defp step(:rule, out, lists, paragraph?, _cite) do
    out = out |> close_paragraph(paragraph?) |> close_lists(lists)
    {[~s(<hr class="my-3 border-zinc-200 dark:border-zinc-700">) | out], [], false}
  end

  defp step({:heading, level, content}, out, lists, paragraph?, cite) do
    out = out |> close_paragraph(paragraph?) |> close_lists(lists)
    size = if level <= 2, do: "text-[15px]", else: "text-sm"

    html =
      ~s(<p class="#{size} font-bold text-zinc-950 dark:text-white mt-3 first:mt-0">) <>
        inline(content, cite) <> "</p>"

    {[html | out], [], false}
  end

  defp step({:item, indent, type, content}, out, lists, paragraph?, cite) do
    out = close_paragraph(out, paragraph?)
    {out, lists} = close_deeper(out, lists, indent)

    {out, lists} =
      case lists do
        # a sibling in the same list
        [{^indent, ^type} | _] ->
          {["</li>" | out], lists}

        # the same depth, another kind of list
        [{^indent, _other} | rest] ->
          {[open_list(type, length(rest)) | close_lists(out, [hd(lists)])],
           [{indent, type} | rest]}

        # deeper (or the first): a new list, inside the open item
        _ ->
          {[open_list(type, length(lists)) | out], [{indent, type} | lists]}
      end

    {[~s(<li>) <> inline(content, cite) | out], lists, false}
  end

  # within a list: an indented line goes on in the item; an unindented one ends the lists
  defp step({:text, indent, content}, out, [_ | _] = lists, paragraph?, cite)
       when indent > 0 and not paragraph? do
    {["<br>" <> inline(content, cite) | out], lists, false}
  end

  defp step({:text, _indent, content}, out, lists, paragraph?, cite) do
    out = close_lists(out, lists)

    if paragraph?,
      do: {["<br>" <> inline(content, cite) | out], [], true},
      else: {[~s(<p class="mt-2 first:mt-0">) <> inline(content, cite) | out], [], true}
  end

  # the lists deeper than an item at `indent`
  defp close_deeper(out, [{open, _} = list | rest], indent) when open > indent,
    do: close_deeper(close_lists(out, [list]), rest, indent)

  defp close_deeper(out, lists, _indent), do: {out, lists}

  defp close_lists(out, lists) do
    Enum.reduce(lists, out, fn {_, type}, out -> ["</li></#{type}>" | out] end)
  end

  defp close_paragraph(out, true), do: ["</p>" | out]
  defp close_paragraph(out, false), do: out

  defp open_list(type, depth) do
    style =
      case {type, depth} do
        {:ol, _} -> "list-decimal"
        {:ul, 0} -> "list-disc"
        {:ul, _} -> "list-[circle]"
      end

    ~s(<#{type} class="#{style} pl-5 space-y-1 mt-1 first:mt-0 marker:text-zinc-400">)
  end

  # escaped, then `code` kept as it is and **bold** / *italics* / citations in the rest
  defp inline(content, cite) do
    content
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
    |> then(&Regex.split(~r/`[^`]+`/u, &1, include_captures: true))
    |> Enum.map_join(fn
      "`" <> _ = code ->
        ~s(<code class="px-1 py-0.5 rounded bg-zinc-100 dark:bg-zinc-800 font-mono text-[12px] text-zinc-900 dark:text-zinc-100">) <>
          String.slice(code, 1..-2//1) <> "</code>"

      text ->
        text
        |> then(
          &Regex.replace(
            ~r/\*\*\s*([^\*\s](?:.*?[^\*\s])?)\s*\*\*/u,
            &1,
            "<strong class=\"font-bold text-zinc-950 dark:text-white\">\\1</strong>"
          )
        )
        |> then(
          &Regex.replace(
            ~r/(?<![*\w])\*\s*([^\*\s](?:.*?[^\*\s])?)\s*\*(?![*\w])/u,
            &1,
            "<em class=\"italic text-zinc-900 dark:text-zinc-100\">\\1</em>"
          )
        )
        |> then(
          &Regex.replace(~r/\[(\d+)\]/u, &1, fn whole, n -> cite.(whole, String.to_integer(n)) end)
        )
    end)
  end
end
