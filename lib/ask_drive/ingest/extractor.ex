defmodule AskDrive.Ingest.Extractor do
  @moduledoc """
  Extracts plain text content from various file formats (Google Workspace, PDF, Office, Text).
  """
  alias AskDrive.Drive.Client, as: DriveClient
  alias AskDrive.Ingest.Extractors.Spreadsheet
  alias AskDrive.Ingest.{FileTypes, TextCleaner}
  alias AskDrive.Runtime.Tools

  @xlsx_mime "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"

  @doc """
  Computes SHA-256 hash of extracted text string.
  """
  def content_hash(text) when is_binary(text) do
    :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)
  end

  @doc """
  Extracts text content for a given document from Google Drive.
  Returns `{:ok, %{text: text, content_hash: hash}}` or `{:skipped, reason}` or `{:error, reason}`.

  Only documents are read (`FileTypes`, spec F-356); anything else is skipped without being
  downloaded (sync already records such files as skipped, so this is a safety net).
  """
  def extract_from_drive(%{drive_file_id: file_id, mime_type: mime_type} = doc) do
    name = Map.get(doc, :name)

    case FileTypes.kind(name, mime_type) do
      nil ->
        {:skipped, FileTypes.excluded_reason(name, mime_type)}

      # Google Docs / Slides -> Export to plain text
      kind when kind in [:google_doc, :google_slides] ->
        case DriveClient.export(file_id, "text/plain") do
          {:ok, binary} -> format_extracted_text(binary)
          {:error, reason} -> {:error, reason}
        end

      # Google Sheets -> Export to XLSX and parse
      :google_sheet ->
        case DriveClient.export(file_id, @xlsx_mime) do
          {:ok, binary} -> extract_kind(binary, :xlsx)
          {:error, reason} -> {:error, reason}
        end

      # Non-workspace files -> Download binary then extract
      kind ->
        case DriveClient.download(file_id) do
          {:ok, binary} -> extract_kind(binary, kind)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc """
  Extracts text content directly from a local binary and MIME type.
  """
  def extract_binary(binary, mime_type) when is_binary(binary) do
    kind =
      cond do
        # HTML carries markup that would otherwise pollute chunk text and embeddings, so it
        # gets the same pandoc-to-plain-text treatment as docx/pptx rather than falling into
        # the raw-passthrough text branch below.
        mime_type in ["text/html", "application/xhtml+xml"] -> :html
        # Plain Text / Markdown / CSV / JSON
        text_mime?(mime_type) -> :text
        true -> FileTypes.kind("", mime_type)
      end

    if kind,
      do: extract_kind(binary, kind),
      else: {:skipped, "Unsupported MIME type: #{mime_type}"}
  end

  defp extract_kind(binary, kind) when kind in [:text, :markdown, :csv],
    do: format_extracted_text(binary)

  defp extract_kind(binary, :html), do: extract_pandoc(binary, "html")
  defp extract_kind(binary, :pdf), do: extract_pdf(binary)
  defp extract_kind(binary, :docx), do: extract_pandoc(binary, "docx")
  defp extract_kind(binary, :pptx), do: extract_pandoc(binary, "pptx")

  defp extract_kind(binary, :xlsx) do
    case Spreadsheet.extract_xlsx(binary) do
      {:ok, text} -> format_extracted_text(text)
      {:error, reason} -> {:error, reason}
    end
  end

  # The old binary formats: LibreOffice turns them into their Open XML successor, which is
  # then read like any .docx / .xlsx / .pptx (pandoc can't read .doc or .ppt at all)
  defp extract_kind(binary, :doc), do: convert_with_libreoffice(binary, "doc", :docx)
  defp extract_kind(binary, :xls), do: convert_with_libreoffice(binary, "xls", :xlsx)
  defp extract_kind(binary, :ppt), do: convert_with_libreoffice(binary, "ppt", :pptx)

  @libreoffice_timeout_s 180

  defp convert_with_libreoffice(binary, from, to) do
    case Tools.libreoffice_path() do
      nil ->
        {:skipped,
         AskDrive.Documents.missing_tool_reason("libreoffice") <>
           " (needed for .#{from} files; see the platform admin's Install & updates tab)"}

      soffice ->
        target = Atom.to_string(to)

        with_temp_file(binary, ".#{from}", fn in_path ->
          # its own profile per run: two conversions at once would otherwise fight over one
          out_dir = in_path <> "_out"
          profile = in_path <> "_profile"

          try do
            args = [
              "-env:UserInstallation=file://#{profile}",
              "--headless",
              "--norestore",
              "--convert-to",
              target,
              "--outdir",
              out_dir,
              in_path
            ]

            {output, code} = run_with_timeout(soffice, args)
            out_file = Path.join(out_dir, Path.basename(in_path, ".#{from}") <> ".#{target}")

            case File.read(out_file) do
              {:ok, converted} ->
                extract_kind(converted, to)

              {:error, _} ->
                {:error,
                 "LibreOffice could not convert the .#{from} file (exit #{code}): #{String.trim(output)}"}
            end
          after
            File.rm_rf(out_dir)
            File.rm_rf(profile)
          end
        end)
    end
  end

  # a broken file can leave LibreOffice hanging; coreutils' timeout stops it (Linux)
  defp run_with_timeout(cmd, args) do
    case System.find_executable("timeout") do
      nil ->
        System.cmd(cmd, args, stderr_to_stdout: true)

      timeout ->
        System.cmd(timeout, ["#{@libreoffice_timeout_s}", cmd | args], stderr_to_stdout: true)
    end
  end

  defp text_mime?(mime) do
    String.starts_with?(mime, "text/") or
      mime in [
        "application/json",
        "application/csv",
        "application/javascript",
        "application/xml",
        "application/x-yaml",
        "text/markdown",
        "text/csv",
        "text/plain"
      ]
  end

  defp extract_pdf(binary) do
    case System.find_executable("pdftotext") do
      nil ->
        {:skipped,
         AskDrive.Documents.missing_tool_reason("pdftotext") <>
           " (see the platform admin's Install & updates tab)"}

      path ->
        with_temp_file(binary, ".pdf", fn temp_path ->
          case System.cmd(path, ["-layout", temp_path, "-"], stderr_to_stdout: true) do
            {output, 0} ->
              output |> clean_pdf_pages() |> format_extracted_text()

            {output, code} ->
              # Exit code 0 or check if output exists
              if byte_size(String.trim(output)) > 0 do
                output |> clean_pdf_pages() |> format_extracted_text()
              else
                {:error, "pdftotext failed (exit #{code}): #{output}"}
              end
          end
        end)
    end
  end

  defp extract_pandoc(binary, format) do
    case System.find_executable("pandoc") do
      nil ->
        {:skipped,
         AskDrive.Documents.missing_tool_reason("pandoc") <>
           " (see the platform admin's Install & updates tab)"}

      path ->
        with_temp_file(binary, ".#{format}", fn temp_path ->
          case System.cmd(path, ["-f", format, "-t", "plain", temp_path], stderr_to_stdout: true) do
            {output, 0} ->
              format_extracted_text(output)

            {output, code} ->
              if byte_size(String.trim(output)) > 0 do
                format_extracted_text(output)
              else
                {:error, "pandoc #{format} extraction failed (exit #{code}): #{output}"}
              end
          end
        end)
    end
  end

  # pdftotext ends every page with a form feed. Clean each page on its own and keep the
  # form feeds (on their own line) so the chunker can tell which page a chunk is on (F-411).
  defp clean_pdf_pages(output) do
    output
    |> String.split("\f")
    |> Enum.map(&TextCleaner.clean/1)
    |> Enum.join("\n\f\n")
  end

  defp format_extracted_text(raw_text) when is_binary(raw_text) do
    cleaned =
      raw_text
      |> String.replace("\r\n", "\n")
      |> String.replace("\r", "\n")
      |> String.trim()

    {:ok, %{text: cleaned, content_hash: content_hash(cleaned)}}
  end

  defp with_temp_file(binary, ext, fun) do
    tmp_dir = System.tmp_dir!()
    random_id = :crypto.strong_rand_bytes(8) |> Base.hex_encode32(case: :lower, padding: false)
    temp_path = Path.join(tmp_dir, "ask_drive_tmp_#{random_id}#{ext}")

    try do
      File.write!(temp_path, binary)
      fun.(temp_path)
    after
      File.rm(temp_path)
    end
  end
end
