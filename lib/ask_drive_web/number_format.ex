defmodule AskDriveWeb.NumberFormat do
  @moduledoc """
  Numbers on the screens (F-1414): every count with a separator every 3 digits
  (`1,234,567`), and the big figures on the cards shortened to fit them — 万 / 億 in
  Japanese, K / M / B in English — with the exact number on hover.
  """
  use Phoenix.Component

  @doc "A whole number with a comma every 3 digits: `1234567` → `\"1,234,567\"`. Nil is 0."
  def num(nil), do: "0"
  def num(n) when is_float(n), do: n |> round() |> num()

  def num(n) when is_integer(n) and n < 0, do: "-" <> num(-n)

  def num(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.to_charlist()
    |> Enum.chunk_every(3)
    |> Enum.join(",")
    |> String.reverse()
  end

  def num(other), do: to_string(other)

  @doc """
  A number short enough for a card: up to 9,999 as it is, then `12.3 万` / `1.2 億`
  (Japanese) or `12.3K` / `123.4M` / `1.2B` (others). `locale` defaults to the current one.
  """
  def compact(n, locale \\ Gettext.get_locale(AskDriveWeb.Gettext))
  def compact(nil, locale), do: compact(0, locale)
  def compact(n, locale) when is_float(n), do: compact(round(n), locale)
  def compact(n, _locale) when is_integer(n) and abs(n) < 10_000, do: num(n)

  def compact(n, "ja" <> _) when is_integer(n) do
    if abs(n) < 100_000_000, do: scaled(n, 10_000, " 万"), else: scaled(n, 100_000_000, " 億")
  end

  def compact(n, _locale) when is_integer(n) do
    cond do
      abs(n) < 1_000_000 -> scaled(n, 1_000, "K")
      abs(n) < 1_000_000_000 -> scaled(n, 1_000_000, "M")
      true -> scaled(n, 1_000_000_000, "B")
    end
  end

  def compact(other, _locale), do: to_string(other)

  # one decimal while it's short (12.3 万), whole numbers after (1,234 万)
  defp scaled(n, unit, suffix) do
    value = n / unit

    text =
      if abs(value) < 100 do
        value
        |> Float.round(1)
        |> :erlang.float_to_binary(decimals: 1)
        |> String.trim_trailing(".0")
      else
        value |> trunc() |> num()
      end

    text <> suffix
  end

  @doc """
  A card's big figure: shortened with `compact/1`, the exact number on hover. Digits keep
  their width and never wrap, so a long figure can't break out of the card.
  """
  attr :value, :any, required: true
  attr :class, :any, default: nil

  def big_number(assigns) do
    ~H"""
    <span title={num(@value)} class={["tabular-nums whitespace-nowrap", @class]}>
      {compact(@value)}
    </span>
    """
  end
end
