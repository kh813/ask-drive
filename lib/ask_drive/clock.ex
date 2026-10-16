defmodule AskDrive.Clock do
  @moduledoc """
  Wall-clock time of the machine AskDrive runs on.

  Batch hours (`batch_start_hour` / `batch_end_hour`, e.g. 21 and 7) are meant in the
  office's local time, but they used to be compared against UTC, so on a JST machine "21:00"
  meant 06:00 in the morning. Timestamps are still stored in UTC; this module converts at
  the edges, using the OS time zone (no tz database needed for a single-site deployment).
  """

  @doc "Current local time, as a NaiveDateTime (seconds precision)."
  def local_now, do: :calendar.local_time() |> NaiveDateTime.from_erl!()

  @doc "Today's date in local time."
  def local_today, do: local_now() |> NaiveDateTime.to_date()

  @doc "Offset of local time from UTC in seconds (e.g. 32400 for JST), rounded to minutes."
  def utc_offset_seconds do
    utc = :calendar.universal_time() |> NaiveDateTime.from_erl!()
    diff = NaiveDateTime.diff(local_now(), utc)
    round(diff / 60) * 60
  end

  @doc "Converts a local NaiveDateTime to a UTC DateTime."
  def local_to_utc(%NaiveDateTime{} = local) do
    local
    |> NaiveDateTime.add(-utc_offset_seconds())
    |> DateTime.from_naive!("Etc/UTC")
  end

  @doc "Converts a UTC DateTime (or NaiveDateTime stored as UTC) to local NaiveDateTime."
  def to_local(nil), do: nil
  def to_local(%DateTime{} = dt), do: dt |> DateTime.to_naive() |> to_local()
  def to_local(%NaiveDateTime{} = utc), do: NaiveDateTime.add(utc, utc_offset_seconds())

  @doc "Formats a stored UTC timestamp in local time."
  def format(nil, _pattern), do: "—"
  def format(dt, pattern), do: dt |> to_local() |> Calendar.strftime(pattern)
end
