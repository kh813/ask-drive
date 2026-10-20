defmodule AskDrive.Ingest.FileTypes do
  @moduledoc """
  Which Drive files the nightly batch indexes (spec F-356): documents only — Google
  Docs/Sheets/Slides, PDF, Word/Excel/PowerPoint (old .doc/.xls/.ppt too, through
  LibreOffice), plain text, Markdown, CSV and HTML. Everything else is left out without being
  downloaded: manuals' folders also hold batch files, programs (.exe) and source code (.py),
  which used to be indexed whenever Drive called them `text/*`.

  An allowlist, so a new kind of file stays out until it's added here. Text files are told
  apart by their extension, since Drive gives `.py` and `.txt` alike a `text/` type.
  """

  # by MIME type: what Drive reports for these is reliable
  @by_mime %{
    "application/vnd.google-apps.document" => :google_doc,
    "application/vnd.google-apps.spreadsheet" => :google_sheet,
    "application/vnd.google-apps.presentation" => :google_slides,
    "application/pdf" => :pdf,
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document" => :docx,
    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" => :xlsx,
    "application/vnd.openxmlformats-officedocument.presentationml.presentation" => :pptx,
    "application/msword" => :doc,
    "application/vnd.ms-excel" => :xls,
    "application/vnd.ms-powerpoint" => :ppt
  }

  # by extension: text files, and documents uploaded with a generic type (octet-stream)
  @by_extension %{
    ".pdf" => :pdf,
    ".docx" => :docx,
    ".xlsx" => :xlsx,
    ".pptx" => :pptx,
    ".doc" => :doc,
    ".xls" => :xls,
    ".ppt" => :ppt,
    ".txt" => :text,
    ".md" => :markdown,
    ".markdown" => :markdown,
    ".csv" => :csv,
    ".html" => :html,
    ".htm" => :html
  }

  # a text file without an extension ("README") still counts when Drive calls it text
  @extensionless_text ~w(text/plain text/markdown text/x-markdown)

  @doc """
  The kind of document a Drive file is, or nil when it isn't indexed. A file whose extension
  isn't on the list is left out even when its type is: `run.bat` reported as `text/plain`.
  """
  def kind(name, mime_type) do
    ext = name |> to_string() |> Path.extname() |> String.downcase()

    cond do
      String.starts_with?(to_string(mime_type), "application/vnd.google-apps.") ->
        Map.get(@by_mime, mime_type)

      ext == "" ->
        Map.get(@by_mime, mime_type) ||
          if(mime_type in @extensionless_text, do: :text)

      true ->
        Map.get(@by_extension, ext)
    end
  end

  @doc "Whether the batch indexes this Drive file."
  def indexable?(name, mime_type), do: kind(name, mime_type) != nil

  @doc """
  The reason stored on a file left out (status "skipped"): it starts with a fixed prefix, so
  such files can be found again (`excluded_reason?/1`) once a rule changes.
  """
  def excluded_reason(name, mime_type) do
    ext = name |> to_string() |> Path.extname()
    what = if ext == "", do: mime_type, else: ext

    "#{excluded_prefix()}#{what} (only documents are indexed: Google Docs/Sheets/Slides, PDF, Word, Excel, PowerPoint, text, Markdown, CSV, HTML)"
  end

  @doc "Whether a stored reason says the file was left out for its type."
  def excluded_reason?(reason) when is_binary(reason),
    do: String.starts_with?(reason, excluded_prefix())

  def excluded_reason?(_), do: false

  defp excluded_prefix, do: "Not a document type: "
end
