defmodule AskDriveWeb.LocaleController do
  use AskDriveWeb, :controller

  @supported_locales AskDriveWeb.Plugs.SetLocale.supported_locales()

  def set_locale(conn, %{"locale" => locale}) do
    locale =
      if locale in @supported_locales,
        do: locale,
        else: AskDriveWeb.Plugs.SetLocale.default_locale()

    redirect_to =
      case get_req_header(conn, "referer") do
        [referer | _] when is_binary(referer) and referer != "" ->
          # Only redirect to relative paths or same host for security
          uri = URI.parse(referer)
          path = uri.path || "/"
          if uri.query, do: "#{path}?#{uri.query}", else: path

        _ ->
          ~p"/"
      end

    conn
    |> put_session("locale", locale)
    |> redirect(to: redirect_to)
  end
end
