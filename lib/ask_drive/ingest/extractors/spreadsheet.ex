defmodule AskDrive.Ingest.Extractors.Spreadsheet do
  @moduledoc """
  Extracts and formats spreadsheet content from XLSX binaries into structured text representation.
  Formats: Sheet name as heading, rows as tab-separated `ColumnName: Value` pairs.
  """

  @doc """
  Extracts text from XLSX binary content.
  """
  def extract_xlsx(binary) when is_binary(binary) do
    case XlsxReader.open(binary, source: :binary) do
      {:ok, package} ->
        sheet_names = XlsxReader.sheet_names(package)

        formatted_sheets =
          Enum.map(sheet_names, fn sheet_name ->
            case XlsxReader.sheet(package, sheet_name) do
              {:ok, rows} -> format_sheet(sheet_name, rows)
              _ -> ""
            end
          end)
          |> Enum.reject(&(&1 == ""))
          |> Enum.join("\n\n")

        {:ok, formatted_sheets}

      {:error, reason} ->
        {:error, "XLSX parsing failed: #{inspect(reason)}"}
    end
  end

  defp format_sheet(sheet_name, []) do
    "## シート: #{sheet_name}\n(空のシート)"
  end

  defp format_sheet(sheet_name, [headers | data_rows]) do
    # Clean header strings
    header_labels =
      headers
      |> Enum.with_index()
      |> Enum.map(fn {val, idx} ->
        str = format_cell(val)
        if str == "", do: "列#{idx + 1}", else: str
      end)

    formatted_rows =
      data_rows
      |> Enum.map(fn row -> format_row(header_labels, row) end)
      |> Enum.reject(&(&1 == ""))

    if Enum.empty?(formatted_rows) do
      "## シート: #{sheet_name}\n" <> Enum.join(header_labels, "\t")
    else
      "## シート: #{sheet_name}\n" <> Enum.join(formatted_rows, "\n")
    end
  end

  defp format_row(headers, row) do
    # Map row cells to header labels
    pairs =
      row
      |> Enum.with_index()
      |> Enum.map(fn {cell_val, idx} ->
        header = Enum.at(headers, idx) || "列#{idx + 1}"
        val_str = format_cell(cell_val)
        {header, val_str}
      end)
      |> Enum.reject(fn {_h, val} -> val == "" end)

    if Enum.empty?(pairs) do
      ""
    else
      pairs
      |> Enum.map(fn {h, v} -> "#{h}: #{v}" end)
      |> Enum.join("\t")
    end
  end

  defp format_cell(nil), do: ""
  defp format_cell(val) when is_binary(val), do: String.trim(val)
  defp format_cell(val) when is_number(val), do: to_string(val)
  defp format_cell(val) when is_boolean(val), do: to_string(val)
  defp format_cell(%Date{} = d), do: Date.to_iso8601(d)
  defp format_cell(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_cell(%NaiveDateTime{} = ndt), do: NaiveDateTime.to_iso8601(ndt)
  defp format_cell(other), do: inspect(other)
end
