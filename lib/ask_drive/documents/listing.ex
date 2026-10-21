defmodule AskDrive.Documents.Listing do
  @moduledoc """
  The desk admin's document list, filtered and sorted (F-1412): by name, status, file type
  (the extension, or the Google type) and token efficiency grade, so the inefficient files,
  or how one file type fares against another, can be picked out. Works on rows of
  `%{document:, efficiency:}`, `efficiency` being `Metrics.calculate_doc_efficiency/2`'s
  result (nil for a document that isn't indexed).
  """

  @google %{
    "application/vnd.google-apps.document" => "Google Docs",
    "application/vnd.google-apps.spreadsheet" => "Google Sheets",
    "application/vnd.google-apps.presentation" => "Google Slides"
  }

  # worst first, as "sort by efficiency" lists them
  @grades ~w(warning poor fair good excellent none)
  @sorts ~w(name efficiency_asc efficiency_desc tokens_desc synced_desc)

  def default_params,
    do: %{"q" => "", "status" => "", "type" => "", "grade" => "", "sort" => "name"}

  def grades, do: @grades
  def sorts, do: @sorts

  @doc "The file type shown and filtered on: `.pdf`, `Google Docs`, or `—` without an extension."
  def file_type(doc) do
    case Map.get(@google, doc.mime_type) do
      nil ->
        case doc.name |> to_string() |> Path.extname() |> String.downcase() do
          "" -> "—"
          ext -> ext
        end

      google ->
        google
    end
  end

  @doc "A row's grade as a string: one of `grades/0`, or \"unrated\" when not indexed."
  def grade(%{efficiency: nil}), do: "unrated"
  def grade(%{efficiency: eff}), do: Atom.to_string(eff.score_level)

  @doc "The rows matching `params` (string keys, as from the form), sorted."
  def filter(rows, params) do
    params = Map.merge(default_params(), params || %{})
    q = params["q"] |> to_string() |> String.trim() |> String.downcase()

    rows
    |> Enum.filter(fn row ->
      (q == "" or String.contains?(String.downcase(row.document.name || ""), q)) and
        matches?(params["status"], row.document.status) and
        matches?(params["type"], file_type(row.document)) and
        matches?(params["grade"], grade(row))
    end)
    |> sort(params["sort"])
  end

  defp matches?(wanted, _value) when wanted in [nil, ""], do: true
  defp matches?(wanted, value), do: wanted == value

  defp sort(rows, "efficiency_asc"), do: Enum.sort_by(rows, &efficiency_key/1, :asc)

  defp sort(rows, "efficiency_desc") do
    {graded, ungraded} = Enum.split_with(rows, &graded?/1)
    Enum.sort_by(graded, &efficiency_key/1, :desc) ++ ungraded
  end

  defp sort(rows, "tokens_desc"),
    do: Enum.sort_by(rows, &((&1.efficiency && &1.efficiency.total_tokens) || 0), :desc)

  defp sort(rows, "synced_desc"),
    do:
      Enum.sort_by(rows, &(&1.document.synced_at || ~U[1970-01-01 00:00:00Z]), {:desc, DateTime})

  defp sort(rows, _name), do: Enum.sort_by(rows, &String.downcase(&1.document.name || ""))

  # a document not indexed, or without chunks, comes last whichever way it's sorted
  defp graded?(%{efficiency: nil}), do: false
  defp graded?(%{efficiency: eff}), do: eff.score_level != :none

  # by grade, then tokens per KB
  defp efficiency_key(%{efficiency: nil}), do: {length(@grades), 0.0}

  defp efficiency_key(%{efficiency: eff}) do
    rank = Enum.find_index(@grades, &(&1 == Atom.to_string(eff.score_level))) || length(@grades)
    {rank, eff.tokens_per_kb || 0.0}
  end

  @doc """
  Totals for the rows shown: how many, their tokens and source size, the tokens per KB
  over them all, and how many of each grade.
  """
  def summary(rows) do
    rated = Enum.filter(rows, & &1.efficiency)
    tokens = Enum.reduce(rated, 0, &(&1.efficiency.total_tokens + &2))
    bytes = Enum.reduce(rated, 0, &(&1.efficiency.raw_size_bytes + &2))

    %{
      count: length(rows),
      total_tokens: tokens,
      total_bytes: bytes,
      tokens_per_kb: if(bytes > 0, do: Float.round(tokens / (bytes / 1024), 1)),
      by_grade: Enum.frequencies_by(rows, &grade/1)
    }
  end

  @doc "The values present in `rows`, for the filter's choices: `%{statuses:, types:}`."
  def choices(rows) do
    %{
      statuses: rows |> Enum.map(& &1.document.status) |> Enum.uniq() |> Enum.sort(),
      types: rows |> Enum.map(&file_type(&1.document)) |> Enum.uniq() |> Enum.sort()
    }
  end
end
