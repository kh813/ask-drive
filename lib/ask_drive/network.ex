defmodule AskDrive.Network do
  @moduledoc """
  Listening ports and trusted reverse proxies (spec F-1013).

  The endpoint serves HTTPS on `https_port` (default 4443) and HTTP on `http_port`
  (default 4000). HTTP from a **trusted proxy** is served as is — the proxy terminates TLS
  and its X-Forwarded-* headers are believed (scheme, host, port, the client's address);
  HTTP from anyone else is redirected to HTTPS. Whether a request comes from a trusted
  proxy is decided by the TCP peer address, which a client can't forge, never by a header.

  The settings live in `<ssl_dir>/listen.json` rather than the database: the endpoint needs
  the ports before the Repo is up, and `./app.sh` reads them for its status and health
  checks. Changing a port restarts the endpoint; if it can't listen on the new ports the
  previous settings are restored. The proxy list applies at once (re-read when the file
  changes, so `./app.sh network proxy-off` takes effect without a restart).
  """
  import Bitwise
  require Logger

  @default_http 4000
  @default_https 4443

  def file, do: Path.join(AskDrive.SSL.ssl_dir(), "listen.json")

  # --- Reading ------------------------------------------------------------------

  @doc "The settings in force: `%{http_port:, https_port:, trusted_proxies: [string]}`."
  def settings do
    # keyed by the path too: the ssl directory can change (tests; ASK_DRIVE_SSL_DIR)
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

  def http_port, do: settings().http_port
  def https_port, do: settings().https_port
  def trusted_proxies, do: settings().trusted_proxies

  defp read do
    stored =
      with {:ok, json} <- File.read(file()),
           {:ok, map} when is_map(map) <- Jason.decode(json),
           do: map,
           else: (_ -> %{})

    %{
      http_port: stored["http_port"] || default_http(),
      https_port:
        stored["https_port"] || Application.get_env(:ask_drive, :https_port, @default_https),
      trusted_proxies: stored["trusted_proxies"] || []
    }
  end

  # the configured default (ASK_DRIVE_HTTP_PORT / PORT in prod), else the endpoint's own
  defp default_http do
    Application.get_env(:ask_drive, :http_port) ||
      get_in(Application.get_env(:ask_drive, AskDriveWeb.Endpoint, []), [:http, :port]) ||
      @default_http
  end

  # --- Trusted proxies ------------------------------------------------------------

  @doc "Whether `ip` (a tuple, the TCP peer) is one of the trusted proxies."
  def trusted?(nil), do: false

  def trusted?(ip) do
    ip = normalize(ip)

    Enum.any?(trusted_proxies(), fn entry ->
      match?({:ok, _}, parse_cidr(entry)) and in_cidr?(ip, entry)
    end)
  end

  defp in_cidr?(ip, entry) do
    {:ok, {net, bits}} = parse_cidr(entry)

    tuple_size(ip) == tuple_size(net) and
      prefix(ip, bits) == prefix(net, bits)
  end

  defp prefix(ip, bits) do
    {int, width} = to_int(ip)
    int >>> (width - bits)
  end

  defp to_int({a, b, c, d}), do: {(a <<< 24) + (b <<< 16) + (c <<< 8) + d, 32}

  defp to_int(ip) when tuple_size(ip) == 8,
    do: {ip |> Tuple.to_list() |> Enum.reduce(0, fn part, acc -> (acc <<< 16) + part end), 128}

  # ::ffff:10.0.0.1 is the IPv4 address 10.0.0.1 (an IPv6 listener sees v4 clients so)
  defp normalize({0, 0, 0, 0, 0, 0xFFFF, hi, lo}),
    do: {hi >>> 8, hi &&& 255, lo >>> 8, lo &&& 255}

  defp normalize(ip), do: ip

  @doc "Parses \"10.0.0.1\" or \"10.0.0.0/24\" (IPv4 or IPv6) into `{:ok, {address, bits}}`."
  def parse_cidr(entry) do
    {addr, bits} =
      case String.split(String.trim(entry), "/", parts: 2) do
        [addr, bits] -> {addr, Integer.parse(bits)}
        [addr] -> {addr, :full}
      end

    with {:ok, ip} <- :inet.parse_strict_address(String.to_charlist(addr)) do
      max = if tuple_size(ip) == 4, do: 32, else: 128

      case bits do
        :full -> {:ok, {normalize(ip), max}}
        {n, ""} when n >= 0 and n <= max -> {:ok, {normalize(ip), n}}
        _ -> {:error, :bad_prefix}
      end
    end
  end

  @doc """
  The client's address from a trusted proxy's headers: CF-Connecting-IP, else the nearest
  address in X-Forwarded-For that isn't itself a trusted proxy. nil when there is none.
  """
  def client_ip(cf_connecting_ip, x_forwarded_for) do
    candidates =
      case cf_connecting_ip do
        v when is_binary(v) and v != "" ->
          [v]

        _ ->
          (x_forwarded_for || "")
          |> String.split(",", trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.reverse()
      end

    Enum.find_value(candidates, fn candidate ->
      case :inet.parse_strict_address(String.to_charlist(candidate)) do
        {:ok, ip} ->
          if trusted?(ip) and candidate != cf_connecting_ip, do: nil, else: normalize(ip)

        _ ->
          nil
      end
    end)
  end

  # --- Changing -------------------------------------------------------------------

  @doc """
  Validates and saves `%{"http_port", "https_port", "trusted_proxies"}` (the proxies as a
  list or as text separated by commas / spaces / new lines). Restarts the endpoint when a
  port changes and rolls back if it won't listen on the new ones.
  Returns `{:ok, settings, :restarted | :applied}` or `{:error, [message]}`.
  """
  def update(params) do
    with {:ok, new} <- validate(params), do: apply_settings(new)
  end

  @doc "Validates like `update/1` without saving: `{:ok, settings}` or `{:error, [message]}`."
  def validate(params), do: validate(params, settings())

  @doc "Whether `new` changes a port (applying it restarts the endpoint)."
  def ports_changed?(new) do
    current = settings()
    new.http_port != current.http_port or new.https_port != current.https_port
  end

  @doc "Saves validated settings; restarts the endpoint (rolling back on failure) if a port changed."
  def apply_settings(new) do
    ports_changed? = ports_changed?(new)
    previous = File.read(file())
    write!(new)

    result =
      if ports_changed? do
        case AskDrive.SSL.restart_endpoint() do
          :ok ->
            Logger.info("Network: listening on HTTP #{new.http_port} / HTTPS #{new.https_port}")
            {:ok, new, :restarted}

          {:error, reason} ->
            Logger.error(
              "Network: endpoint failed on the new ports (#{inspect(reason)}); rolling back"
            )

            restore!(previous)
            AskDrive.SSL.restart_endpoint()
            {:error, ["新しいポートで起動できなかったため、元の設定に戻しました: #{inspect(reason)}"]}
        end
      else
        {:ok, new, :applied}
      end

    :persistent_term.put({__MODULE__, :last_result}, result)
    result
  end

  @doc "The outcome of the last change (shown after the endpoint restart reconnects the page)."
  def last_result, do: :persistent_term.get({__MODULE__, :last_result}, nil)

  @doc "Forgets every trusted proxy (`./app.sh network proxy-off`): HTTP redirects again."
  def clear_proxies!, do: write!(%{settings() | trusted_proxies: []})

  @doc "Back to the default ports (`./app.sh network ports-reset`); takes effect on restart."
  def reset_ports! do
    write!(%{
      settings()
      | http_port: default_http(),
        https_port: Application.get_env(:ask_drive, :https_port, @default_https)
    })
  end

  defp validate(params, current) do
    http = parse_port(params["http_port"], current.http_port)
    https = parse_port(params["https_port"], current.https_port)
    proxies = parse_proxies(Map.get(params, "trusted_proxies", current.trusted_proxies))

    errors =
      [
        match?(:error, http) && "HTTP のポートは 1〜65535 の数字にしてください",
        match?(:error, https) && "HTTPS のポートは 1〜65535 の数字にしてください",
        http == https && "HTTP と HTTPS に同じポートは使えません",
        match?({:error, _}, proxies) &&
          "プロキシの IP として読み取れません: #{elem(proxies, 1) |> List.wrap() |> Enum.join("、")}"
      ]
      |> Enum.filter(&is_binary/1)

    errors =
      if errors == [] do
        [{http, current.http_port, "HTTP"}, {https, current.https_port, "HTTPS"}]
        |> Enum.flat_map(fn {{:ok, port}, old, label} ->
          if port != old and not port_free?(port),
            do: ["#{label} のポート #{port} は、ほかのプログラムが使用中です"],
            else: []
        end)
      else
        errors
      end

    if errors == [] do
      {:ok, http} = http
      {:ok, https} = https
      {:ok, proxies} = proxies
      {:ok, %{http_port: http, https_port: https, trusted_proxies: proxies}}
    else
      {:error, errors}
    end
  end

  defp parse_port(nil, current), do: {:ok, current}
  defp parse_port(port, _current) when is_integer(port) and port in 1..65_535, do: {:ok, port}

  defp parse_port(text, current) when is_binary(text) do
    case Integer.parse(String.trim(text)) do
      {port, ""} when port in 1..65_535 -> {:ok, port}
      _ -> if String.trim(text) == "", do: {:ok, current}, else: :error
    end
  end

  defp parse_port(_, _), do: :error

  defp parse_proxies(list) when is_list(list), do: list |> Enum.join(",") |> parse_proxies()

  defp parse_proxies(text) when is_binary(text) do
    entries = text |> String.split(~r/[\s,;、]+/, trim: true) |> Enum.uniq()
    bad = Enum.reject(entries, &match?({:ok, _}, parse_cidr(&1)))
    if bad == [], do: {:ok, entries}, else: {:error, bad}
  end

  defp parse_proxies(_), do: {:ok, []}

  @doc "Whether nothing listens on `port` yet."
  def port_free?(port) do
    case :gen_tcp.listen(port, [:binary, reuseaddr: true, ip: {0, 0, 0, 0}]) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      {:error, _} ->
        false
    end
  end

  defp write!(settings) do
    File.mkdir_p!(Path.dirname(file()))

    File.write!(
      file(),
      Jason.encode!(
        %{
          "http_port" => settings.http_port,
          "https_port" => settings.https_port,
          "trusted_proxies" => settings.trusted_proxies
        },
        pretty: true
      )
    )

    :persistent_term.erase({__MODULE__, :cache})
    :ok
  end

  defp restore!({:ok, json}),
    do: File.write!(file(), json) && :persistent_term.erase({__MODULE__, :cache})

  defp restore!(_), do: File.rm(file()) && :persistent_term.erase({__MODULE__, :cache})
end
