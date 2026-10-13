defmodule AskDrive.Gateway do
  @moduledoc """
  An API gateway in front of AskDrive (spec F-1014), such as Sakura Cloud's API Gateway with
  Google Workspace sign-in (OIDC): only people who passed the gateway reach AskDrive, and so
  only they see its login page.

  The gateway adds a secret header (`X-Apigw-Secret`) to every request it forwards. With a
  secret set here, a request without it — someone going around the gateway — is refused with
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

  alias AskDrive.Network

  @header "x-apigw-secret"
  @min_secret 16

  def header, do: @header
  def file, do: Path.join(AskDrive.SSL.ssl_dir(), "gateway.json")

  # --- Reading --------------------------------------------------------------------

  @doc "`%{secret: string | nil, public_url: string | nil, direct_ranges: [string]}`."
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

    %{
      secret: blank_to_nil(stored["secret"]),
      public_url: blank_to_nil(stored["public_url"]),
      direct_ranges: stored["direct_ranges"] || []
    }
  end

  @doc "Whether requests must come through the gateway (a secret is set)."
  def enabled?, do: settings().secret != nil

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
  Validates `%{"secret", "public_url", "direct_ranges", "disable"}`. A blank secret keeps the
  stored one; `"disable" => "true"` removes it (the gate opens). Returns `{:ok, settings}` or
  `{:error, [message]}`.
  """
  def validate(params) do
    current = settings()

    secret =
      cond do
        params["disable"] in ["true", true] -> nil
        blank?(params["secret"]) -> current.secret
        true -> String.trim(params["secret"])
      end

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
          "秘密の値は #{@min_secret} 文字以上にしてください",
        secret && Regex.match?(~r/[\s"\\]/, secret) && "秘密の値に空白・引用符・バックスラッシュは使えません",
        public_url && not valid_public_url?(public_url) &&
          "公開 URL は https://app.example.com の形（パスなし）で入力してください",
        secret && is_nil(public_url) && "ゲートウェイを有効にするには公開 URL が必要です",
        match?({:error, _}, ranges) &&
          "直接アクセスを許可する IP として読み取れません: #{elem(ranges, 1) |> List.wrap() |> Enum.join("、")}"
      ]
      |> Enum.filter(&is_binary/1)

    if errors == [] do
      {:ok, ranges} = ranges
      {:ok, %{secret: secret, public_url: public_url, direct_ranges: ranges}}
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

  @doc "Removes the secret (`./app.sh network gateway-off`): direct access works again."
  def disable!, do: save!(%{settings() | secret: nil})

  defp blank?(v), do: not is_binary(v) or String.trim(v) == ""
  defp blank_to_nil(v), do: if(blank?(v), do: nil, else: v)
end
