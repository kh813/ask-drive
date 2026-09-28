defmodule AskDrive.Ingest.Extractor do
  @moduledoc """
  Extracts plain text content from various file formats (Google Workspace, PDF, Office, Text).
  """
  alias AskDrive.Drive.Client, as: DriveClient
  alias AskDrive.Ingest.Extractors.Spreadsheet
  alias AskDrive.Ingest.TextCleaner

  @doc """
  Computes SHA-256 hash of extracted text string.
  """
  def content_hash(text) when is_binary(text) do
    :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)
  end

  @doc """
  Extracts text content for a given document from Google Drive.
  Returns `{:ok, %{text: text, content_hash: hash}}` or `{:skipped, reason}` or `{:error, reason}`.
  """
  def extract_from_drive(%{drive_file_id: file_id, mime_type: mime_type} = _doc) do
    case mime_type do
      # Google Docs / Slides -> Export to plain text
      "application/vnd.google-apps.document" ->
        case DriveClient.export(file_id, "text/plain") do
          {:ok, binary} -> format_extracted_text(binary)
          {:error, reason} -> {:error, reason}
        end

      "application/vnd.google-apps.presentation" ->
        case DriveClient.export(file_id, "text/plain") do
          {:ok, binary} -> format_extracted_text(binary)
          {:error, reason} -> {:error, reason}
        end

      # Google Sheets -> Export to XLSX and parse
      "application/vnd.google-apps.spreadsheet" ->
        xlsx_mime = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"

        case DriveClient.export(file_id, xlsx_mime) do
          {:ok, binary} ->
            case Spreadsheet.extract_xlsx(binary) do
              {:ok, text} -> format_extracted_text(text)
              {:error, reason} -> {:error, reason}
            end

          {:error, reason} ->
            {:error, reason}
        end

      # Non-workspace files -> Download binary then extract
      _ ->
        case DriveClient.download(file_id) do
          {:ok, binary} -> extract_binary(binary, mime_type)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc """
  Extracts text content directly from a local binary and MIME type.
  """
  def extract_binary(binary, mime_type) when is_binary(binary) do
    cond do
      # HTML carries markup that would otherwise pollute chunk text and embeddings, so it
      # gets the same pandoc-to-plain-text treatment as docx/pptx rather than falling into
      # the raw-passthrough text branch below.
      mime_type in ["text/html", "application/xhtml+xml"] ->
        extract_pandoc(binary, "html")

      # Plain Text / Markdown / CSV / JSON
      text_mime?(mime_type) ->
        format_extracted_text(binary)

      # XLSX
      mime_type == "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" ->
        case Spreadsheet.extract_xlsx(binary) do
          {:ok, text} -> format_extracted_text(text)
          {:error, reason} -> {:error, reason}
        end

      # PDF
      mime_type == "application/pdf" ->
        extract_pdf(binary)

      # DOCX / PPTX
      mime_type in [
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "application/msword"
      ] ->
        extract_pandoc(binary, "docx")

      mime_type in [
        "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        "application/vnd.ms-powerpoint"
      ] ->
        extract_pandoc(binary, "pptx")

      true ->
        {:skipped, "Unsupported MIME type: #{mime_type}"}
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
        {:skipped, "Missing external CLI tool: pdftotext (install via `brew install poppler`)"}

      path ->
        with_temp_file(binary, ".pdf", fn temp_path ->
          case System.cmd(path, ["-layout", temp_path, "-"], stderr_to_stdout: true) do
            {output, 0} ->
              output |> TextCleaner.clean() |> format_extracted_text()

            {output, code} ->
              # Exit code 0 or check if output exists
              if byte_size(String.trim(output)) > 0 do
                output |> TextCleaner.clean() |> format_extracted_text()
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
        {:skipped, "Missing external CLI tool: pandoc (install via `brew install pandoc`)"}

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
