defmodule AskDriveWeb.Plugs.SetLocale do
  @moduledoc """
  Plug and LiveView on_mount hook to detect and set the active locale.
  Supported locales: "en" (default), "ja".

  Resolution precedence:
  1. Explicit query parameter `locale=...` (if valid)
  2. Session stored `"locale"` (if valid)
  3. Browser `Accept-Language` header
  4. Default locale ("en")
  """
  import Plug.Conn

  @supported_locales ~w(en ja)
  @default_locale "en"

  def supported_locales, do: @supported_locales
  def default_locale, do: @default_locale

  def init(opts), do: opts

  def call(conn, _opts) do
    locale = resolve_locale(conn)
    Gettext.put_locale(AskDriveWeb.Gettext, locale)

    conn
    |> put_session("locale", locale)
    |> assign(:locale, locale)
  end

  @doc """
  LiveView on_mount hook to synchronize locale from session to Gettext process dict and socket assigns.
  """
  def on_mount(:default, _params, session, socket) do
    locale =
      case Map.get(session, "locale") do
        loc when loc in @supported_locales -> loc
        _ -> @default_locale
      end

    Gettext.put_locale(AskDriveWeb.Gettext, locale)
    {:cont, Phoenix.Component.assign(socket, :locale, locale)}
  end

  def resolve_locale(conn) do
    param_locale =
      case conn.params do
        %Plug.Conn.Unfetched{} ->
          try do
            conn = Plug.Conn.fetch_query_params(conn)
            conn.query_params["locale"]
          rescue
            _ -> nil
          end

        params when is_map(params) ->
          params["locale"]

        _ ->
          nil
      end

    session_locale =
      case conn.private do
        %{plug_session: _} -> get_session(conn, "locale")
        _ -> nil
      end

    header_locale = parse_accept_language(get_req_header(conn, "accept-language"))

    cond do
      param_locale in @supported_locales -> param_locale
      session_locale in @supported_locales -> session_locale
      header_locale in @supported_locales -> header_locale
      true -> @default_locale
    end
  end

  def parse_accept_language([]), do: nil

  def parse_accept_language([header | _]) when is_binary(header) do
    header
    |> String.split(",")
    |> Enum.map(&parse_lang_tag/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(&elem(&1, 1), :desc)
    |> Enum.find_value(fn {lang, _q} ->
      cond do
        String.starts_with?(lang, "ja") -> "ja"
        String.starts_with?(lang, "en") -> "en"
        true -> nil
      end
    end)
  end

  defp parse_lang_tag(tag) do
    case String.split(String.trim(tag), ";") do
      [lang] ->
        {String.downcase(String.trim(lang)), 1.0}

      [lang, q_part] ->
        q =
          case Regex.run(~r/q=([0-9.]+)/, q_part) do
            [_, q_val] ->
              case Float.parse(q_val) do
                {val, _} -> val
                :error -> 0.0
              end

            _ ->
              1.0
          end

        {String.downcase(String.trim(lang)), q}

      _ ->
        nil
    end
  end
end
