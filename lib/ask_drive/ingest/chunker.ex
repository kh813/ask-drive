defmodule AskDrive.Ingest.Chunker do
  @moduledoc """
  Splits extracted document text into semantic chunks with heading awareness,
  Japanese/English sentence boundary preservation, size budgeting, and overlap.
  """
  alias AskDrive.Ingest.Extractor

  @default_target_size 600
  @default_max_size 1200
  @default_overlap_size 100
  @min_chunk_size 20

  @doc """
  Chunks a text document.
  Options:
    - `:doc_name` - Document title/name to prepend to chunks
    - `:target_size` - Target chunk character length (default 600)
    - `:max_size` - Maximum character length before forced split (default 1200)
    - `:overlap_size` - Number of characters to overlap between chunks (default 100)
  """
  def chunk(text, opts \\ []) when is_binary(text) do
    doc_name = Keyword.get(opts, :doc_name, "")
    target_size = Keyword.get(opts, :target_size, @default_target_size)
    max_size = Keyword.get(opts, :max_size, @default_max_size)
    overlap_size = Keyword.get(opts, :overlap_size, @default_overlap_size)

    # PDF text carries a form feed per page break (F-411). Chunk the text without them and
    # remember where each page starts, to stamp every chunk with its page afterwards.
    {text, page_starts} = strip_page_breaks(text)

    sections = split_sections(text)

    {raw_chunks, _pos} =
      Enum.reduce(sections, {[], 0}, fn {heading, section_text}, {acc_chunks, pos} ->
        section_chunks =
          section_text
          |> split_sentences()
          |> pack_sentences(target_size, max_size, overlap_size)
          |> Enum.map(fn chunk_text ->
            formatted_content = format_chunk_content(doc_name, heading, chunk_text)

            %{
              heading: heading,
              content: formatted_content,
              token_estimate: estimate_tokens(formatted_content),
              content_hash: Extractor.content_hash(formatted_content),
              body: chunk_text
            }
          end)
          |> Enum.filter(fn c -> String.length(c.content) >= @min_chunk_size end)

        # Assign incremental position
        indexed_chunks =
          section_chunks
          |> Enum.with_index(pos)
          |> Enum.map(fn {c, idx} -> Map.put(c, :position, idx) end)

        {acc_chunks ++ indexed_chunks, pos + length(indexed_chunks)}
      end)

    assign_pages(raw_chunks, text, page_starts)
  end

  defp strip_page_breaks(text) do
    if String.contains?(text, "\f") do
      pages = String.split(text, "\f")

      {starts, _} =
        pages
        |> Enum.with_index(1)
        |> Enum.map_reduce(0, fn {page_text, n}, offset ->
          {{offset, n}, offset + byte_size(page_text) + 1}
        end)

      {Enum.join(pages, "\n"), starts}
    else
      {text, []}
    end
  end

  # Finds each chunk's opening words in the page-joined text (searching forward from the
  # previous chunk, since chunks come in document order) and maps the byte offset to a page.
  defp assign_pages(chunks, _text, []),
    do: Enum.map(chunks, &(&1 |> Map.delete(:body) |> Map.put(:page, nil)))

  defp assign_pages(chunks, text, page_starts) do
    {with_pages, _} =
      Enum.map_reduce(chunks, {0, 1}, fn chunk, {cursor, last_page} ->
        {offset, page} =
          case locate(text, chunk.body, cursor) do
            nil -> {cursor, last_page}
            offset -> {offset, page_at(page_starts, offset)}
          end

        {chunk |> Map.delete(:body) |> Map.put(:page, page), {offset, page}}
      end)

    with_pages
  end

  defp locate(text, body, cursor) do
    body = String.trim(body)

    Enum.find_value([24, 12, 6], fn len ->
      needle = String.slice(body, 0, len)

      if needle != "" do
        case :binary.match(text, needle, scope: {cursor, byte_size(text) - cursor}) do
          {pos, _} -> pos
          :nomatch -> nil
        end
      end
    end)
  end

  defp page_at(page_starts, offset) do
    page_starts
    |> Enum.take_while(fn {start, _n} -> start <= offset end)
    |> List.last()
    |> elem(1)
  end

  # Splits text into sections based on markdown headers or major section dividers
  defp split_sections(text) do
    lines = String.split(text, "\n")

    {sections, current_heading, current_lines} =
      Enum.reduce(lines, {[], "全体", []}, fn line, {acc, heading, cur_lines} ->
        trimmed = String.trim(line)

        cond do
          # Markdown header (# Heading, ## Heading, etc.)
          String.starts_with?(trimmed, "#") ->
            clean_heading = String.trim_leading(trimmed, "#") |> String.trim()
            content = Enum.reverse(cur_lines) |> Enum.join("\n") |> String.trim()

            new_acc =
              if content != "" do
                [{heading, content} | acc]
              else
                acc
              end

            {new_acc, clean_heading, []}

          true ->
            {acc, heading, [line | cur_lines]}
        end
      end)

    final_content = Enum.reverse(current_lines) |> Enum.join("\n") |> String.trim()

    all_sections =
      if final_content != "" do
        [{current_heading, final_content} | sections]
      else
        sections
      end

    Enum.reverse(all_sections)
  end

  # Splits text into sentences supporting Japanese (。！？) and English (.!?)
  defp split_sentences(text) do
    # Replace sentence delimiters with delimiter + special separator \u0000
    text
    |> String.replace(~r/([。！？\n]{1,2})/u, "\\1\u0000")
    |> String.replace(~r/([.!?])\s+/u, "\\1 \u0000")
    |> String.split("\u0000", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  # Packs sentences into chunks respecting target_size and overlap
  defp pack_sentences([], _target, _max, _overlap), do: []

  defp pack_sentences(sentences, target_size, max_size, overlap_size) do
    do_pack(sentences, "", [], target_size, max_size, overlap_size)
  end

  defp do_pack([], current_chunk, acc, _target, _max, _overlap) do
    if String.trim(current_chunk) != "" do
      Enum.reverse([String.trim(current_chunk) | acc])
    else
      Enum.reverse(acc)
    end
  end

  defp do_pack([sentence | rest], current_chunk, acc, target_size, max_size, overlap_size) do
    # If a single sentence exceeds max_size, force split it
    if String.length(sentence) > max_size do
      forced_parts = force_split(sentence, target_size)
      do_pack(forced_parts ++ rest, current_chunk, acc, target_size, max_size, overlap_size)
    else
      candidate =
        if current_chunk == "" do
          sentence
        else
          current_chunk <> "\n" <> sentence
        end

      cond do
        String.length(candidate) <= target_size ->
          do_pack(rest, candidate, acc, target_size, max_size, overlap_size)

        String.length(current_chunk) == 0 ->
          # First sentence exceeds target_size but <= max_size
          do_pack(rest, "", [candidate | acc], target_size, max_size, overlap_size)

        true ->
          # Finished current chunk, create overlap for next chunk
          overlap = take_tail(current_chunk, overlap_size)

          new_current =
            if overlap != "" and not String.contains?(sentence, overlap) do
              overlap <> "\n" <> sentence
            else
              sentence
            end

          do_pack(
            rest,
            new_current,
            [String.trim(current_chunk) | acc],
            target_size,
            max_size,
            overlap_size
          )
      end
    end
  end

  defp take_tail(str, size) do
    if String.length(str) <= size do
      str
    else
      String.slice(str, -size, size)
    end
  end

  defp force_split("", _chunk_size), do: []

  defp force_split(str, chunk_size) do
    len = String.length(str)

    if len <= chunk_size do
      [str]
    else
      head = String.slice(str, 0, chunk_size)
      tail = String.slice(str, chunk_size, len - chunk_size)
      [head | force_split(tail, chunk_size)]
    end
  end

  defp format_chunk_content(doc_name, heading, chunk_text) do
    header =
      cond do
        doc_name != "" and heading != "" and heading != "全体" ->
          "[文書: #{doc_name} | セクション: #{heading}]\n"

        doc_name != "" ->
          "[文書: #{doc_name}]\n"

        heading != "" and heading != "全体" ->
          "[セクション: #{heading}]\n"

        true ->
          ""
      end

    header <> chunk_text
  end

  # Approximate token count (roughly 1.5 chars per token for Japanese/English mixed)
  defp estimate_tokens(text) do
    (String.length(text) / 1.5) |> round()
  end
end
