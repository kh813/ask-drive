defmodule AskDrive.Gateway do
  @moduledoc """
  An API gateway in front of AskDrive (spec F-1014), such as Sakura Cloud's API Gateway with
  Google Workspace sign-in (OIDC): only people who passed the gateway reach AskDrive, and so
  only they see its login page.

  The gateway adds a secret header (`X-Apigw-Secret`) to every request it forwards. With a
  secret set here and the check switched on (`enabled`, a separate switch from saving the
  values, F-206), a request without it — someone going around the gateway — is refused with
  403 (`AskDriveWeb.Plugs.GatewayGate`, which runs before anything else, the LiveView socket
  included). Requests that carry it are the gateway's: its X-Forwarded-For is believed for
  the client's address (as from a trusted proxy, F-1013), and the URLs AskDrive builds use the
  **public URL** (`https://app.example.com`) whatever host name the gateway sent
  (`origin.example.com`), so links, redirects and the Google login's redirect URI never point
  at the origin, where the browser has no secret to send.

  Two ways in without the header: the server itself (loopback) always, as a way back; and the
  address ranges listed in `direct_ranges` (e.g. the office LAN while it still connects
  directly; empty by default).

  Kept in `<ssl_dir>/gateway.json` (0600) rather than the database: the gate runs on every
  request before the Repo is touched, and `./app.sh network gateway-off` must be able to turn
  it off when the admin screen can't be reached. Re-read when the file changes.
  """

  use Gettext, backend: AskDriveWeb.Gettext

  alias AskDrive.Network

  @header "x-apigw-secret"
  @min_secret 16

  def header, do: @header
  def file, do: Path.join(AskDrive.SSL.ssl_dir(), "gateway.json")

  # --- Reading --------------------------------------------------------------------

  @doc """
  `%{enabled: boolean, secret: string | nil, public_url: string | nil, direct_ranges: [string]}`.
  A file from v0.1.38 has no `enabled`: a secret there meant on.
  """
  def settings do
    stat = {file(), File.stat(file())}
    key = {__MODULE__, :cache}

    case :persistent_term.get(key, nil) do
      {^stat, settings} ->
        settings

      _ ->
        settings = read()
        :persistent_term.put(key, {stat, settings})
        settings
    end
  end

  defp read do
    stored =
      with {:ok, json} <- File.read(file()),
           {:ok, map} when is_map(map) <- Jason.decode(json),
           do: map,
           else: (_ -> %{})

    secret = blank_to_nil(stored["secret"])

    %{
      enabled: Map.get(stored, "enabled", secret != nil) == true,
      secret: secret,
      public_url: blank_to_nil(stored["public_url"]),
      direct_ranges: stored["direct_ranges"] || []
    }
  end

  @doc "Whether requests must come through the gateway (switched on, with a secret)."
  def enabled? do
    s = settings()
    s.enabled and s.secret != nil
  end

  @doc "What is missing before the check can be switched on (`[]` when nothing)."
  def enable_problems(settings \\ settings()) do
    [
      is_nil(settings.secret) && gettext("Save the secret header value"),
      is_nil(settings.public_url) && gettext("Save the public URL")
    ]
    |> Enum.filter(&is_binary/1)
  end

  @doc "Whether `value` (the header a request carried) is the secret. Constant time."
  def valid_secret?(value) when is_binary(value) do
    case settings().secret do
      nil -> false
      secret -> Plug.Crypto.secure_compare(value, secret)
    end
  end

  def valid_secret?(_), do: false

  @doc "Whether `ip` (the TCP peer) may come in without the header: loopback or a listed range."
  def direct_allowed?(ip, ranges \\ settings().direct_ranges)
  def direct_allowed?(nil, _ranges), do: false

  def direct_allowed?(ip, ranges),
    do: loopback?(ip) or Network.in_ranges?(ip, ranges)

  defp loopback?({127, _, _, _}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0xFFFF, a, _}), do: div(a, 256) == 127
  defp loopback?(_), do: false

  @doc "The public URL parsed: `%URI{scheme, host, port}`, or nil."
  def public_uri do
    case settings().public_url do
      nil -> nil
      url -> URI.parse(url)
    end
  end

  # --- Changing -------------------------------------------------------------------

  @doc """
  Validates the values `%{"secret", "public_url", "direct_ranges"}` (whether the check is on
  is kept as it is). A blank secret keeps the stored one. While the check is on, the secret
  and the public URL can't be emptied. Returns `{:ok, settings}` or `{:error, [message]}`.
  """
  def validate(params) do
    current = settings()

    secret =
      if blank?(params["secret"]), do: current.secret, else: String.trim(params["secret"])

    public_url = params |> Map.get("public_url", current.public_url) |> blank_to_nil()
    public_url = public_url && public_url |> String.trim() |> String.trim_trailing("/")

    ranges =
      case params["direct_ranges"] do
        nil -> {:ok, current.direct_ranges}
        list when is_list(list) -> Network.parse_ranges(Enum.join(list, ","))
        text -> Network.parse_ranges(text)
      end

    errors =
      [
        secret && String.length(secret) < @min_secret &&
          gettext("The secret value must be at least %{count} characters", count: @min_secret),
        secret && Regex.match?(~r/[\s"\\]/, secret) &&
          gettext("The secret value can't contain spaces, quotes or backslashes"),
        public_url && not valid_public_url?(public_url) &&
          gettext("Enter the public URL as https://app.example.com (no path)"),
        current.enabled && is_nil(public_url) &&
          gettext("The public URL can't be emptied while the check is on (turn it off first)"),
        match?({:error, _}, ranges) &&
          gettext("Can't read these as IPs allowed direct access: %{values}",
            values: elem(ranges, 1) |> List.wrap() |> Enum.join(gettext(", "))
          )
      ]
      |> Enum.filter(&is_binary/1)

    if errors == [] do
      {:ok, ranges} = ranges

      {:ok,
       %{enabled: current.enabled, secret: secret, public_url: public_url, direct_ranges: ranges}}
    else
      {:error, errors}
    end
  end

  defp valid_public_url?(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host, path: path, query: nil, fragment: nil}
      when is_binary(host) and host != "" and path in [nil, ""] ->
        true

      _ ->
        false
    end
  end

  @doc "Saves validated settings (applies at once)."
  def save!(settings) do
    File.mkdir_p!(Path.dirname(file()))

    File.write!(
      file(),
      Jason.encode!(
        %{
          "enabled" => settings.enabled,
          "secret" => settings.secret,
          "public_url" => settings.public_url,
          "direct_ranges" => settings.direct_ranges
        },
        pretty: true
      )
    )

    File.chmod!(file(), 0o600)
    :persistent_term.erase({__MODULE__, :cache})
    :ok
  end

  @doc "Switches the check on or off, keeping the values."
  def set_enabled!(on?), do: save!(%{settings() | enabled: on?})

  @doc "Switches the check off (`./app.sh network gateway-off`): direct access works again."
  def disable!, do: set_enabled!(false)

  defp blank?(v), do: not is_binary(v) or String.trim(v) == ""
  defp blank_to_nil(v), do: if(blank?(v), do: nil, else: v)
end
