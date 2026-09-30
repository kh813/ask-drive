defmodule AskDrive.ClientCerts do
  @moduledoc """
  Access only from devices with a client certificate issued by AskDrive (spec 6.14).

  AskDrive keeps its own certificate authority (`<ssl_dir>/client_ca/`). An administrator
  issues a certificate per **group** (a department, say): a password-protected `.p12`
  (key + certificate + CA) to install in the browser / OS of the group's devices. Who a
  person is is still decided by signing in; the certificate says the device is one of ours.

  The HTTPS listener asks the browser for a certificate — optionally, so a device without
  one isn't cut off at the TLS layer with a bare browser error — and the check happens in
  the app (`AskDriveWeb.Plugs.ClientCertGate`), before the login page, so it can explain.

  Modes (`<ssl_dir>/mtls.json`, read before the Repo is up and re-read when it changes):

    * `off` — no certificate asked for (default);
    * `monitor` — asked for and recorded (who still comes without one), nobody refused;
    * `enforce` — requests without a valid certificate get the explanation page.

  A certificate is valid when it was issued here (its serial is known), isn't revoked and
  hasn't expired. Requests from the server itself (localhost) always pass, as a way back in;
  `./app.sh mtls off` switches it off from the command line.
  """
  import Ecto.Query
  require Logger
  alias AskDrive.ClientCerts.{Cert, Group}
  alias AskDrive.PlatformRepo

  @modes ~w(off monitor enforce)
  @cert_days 365
  @ca_days 3650

  def modes, do: @modes
  def dir, do: Path.join(AskDrive.SSL.ssl_dir(), "client_ca")
  def mode_file, do: Path.join(AskDrive.SSL.ssl_dir(), "mtls.json")

  # --- Mode ---------------------------------------------------------------------------

  @doc "The mode in force: \"off\", \"monitor\" or \"enforce\"."
  def mode, do: config().mode

  @doc """
  The office LAN (spec F-1408): addresses / ranges from which no certificate is needed.
  The client's address is the TCP peer, or — through a trusted reverse proxy (F-1013) —
  the address the proxy reports.
  """
  def lan_ranges, do: config().lan

  def lan?(ip), do: AskDrive.Network.in_ranges?(ip, lan_ranges())

  # `<ssl_dir>/mtls.json`, re-read when it changes (./app.sh mtls off applies at once)
  defp config do
    key = {__MODULE__, :config}
    stat = {mode_file(), File.stat(mode_file())}

    case :persistent_term.get(key, nil) do
      {^stat, config} ->
        config

      _ ->
        stored =
          with {:ok, json} <- File.read(mode_file()),
               {:ok, map} when is_map(map) <- Jason.decode(json),
               do: map,
               else: (_ -> %{})

        config = %{
          mode: if(stored["mode"] in @modes, do: stored["mode"], else: "off"),
          lan: if(is_list(stored["lan"]), do: stored["lan"], else: [])
        }

        :persistent_term.put(key, {stat, config})
        config
    end
  end

  defp write_config!(config) do
    File.mkdir_p!(Path.dirname(mode_file()))

    File.write!(
      mode_file(),
      Jason.encode!(%{"mode" => config.mode, "lan" => config.lan}, pretty: true)
    )

    :persistent_term.erase({__MODULE__, :config})
    :ok
  end

  @doc "Whether the HTTPS listener must ask for certificates (restart when this changes)."
  def request_certs?, do: mode() != "off"

  @doc "Sets the mode. Returns `{:ok, restart_needed?}` (asking for certificates starts / stops)."
  def set_mode(mode) when mode in @modes do
    before = request_certs?()
    if mode != "off", do: ensure_ca!()
    :ok = write_config!(%{config() | mode: mode})
    {:ok, before != request_certs?()}
  end

  @doc "Sets the office LAN ranges from text (commas / spaces / new lines): `:ok` or `{:error, invalid}`."
  def set_lan_ranges(text) do
    with {:ok, entries} <- AskDrive.Network.parse_ranges(to_string(text)) do
      write_config!(%{config() | lan: entries})
    end
  end

  # --- The certificate authority ------------------------------------------------------

  def ca_cert_path, do: Path.join(dir(), "ca.pem")
  defp ca_key_path, do: Path.join(dir(), "ca.key")

  @doc "Creates the CA on first use (key readable by the owner only)."
  def ensure_ca! do
    unless File.exists?(ca_cert_path()) do
      File.mkdir_p!(dir())

      openssl!([
        "req",
        "-x509",
        "-newkey",
        "rsa:2048",
        "-nodes",
        "-sha256",
        "-days",
        to_string(@ca_days),
        "-keyout",
        ca_key_path(),
        "-out",
        ca_cert_path(),
        "-subj",
        "/CN=AskDrive Client CA/O=AskDrive",
        "-addext",
        "basicConstraints=critical,CA:TRUE",
        "-addext",
        "keyUsage=critical,keyCertSign,cRLSign"
      ])

      File.chmod!(ca_key_path(), 0o600)
      Logger.info("ClientCerts: created the client-certificate CA in #{dir()}")
    end

    :ok
  end

  @doc "The CA certificate (DER), for the TLS listener; nil when there is none."
  def ca_der do
    with {:ok, pem} <- File.read(ca_cert_path()),
         [{:Certificate, der, _} | _] <- :public_key.pem_decode(pem),
         do: der,
         else: (_ -> nil)
  end

  # --- Groups and certificates ---------------------------------------------------------

  def list_groups do
    PlatformRepo.all(
      from g in Group,
        order_by: g.name,
        preload: [
          certs:
            ^from(c in Cert,
              order_by: [desc: c.inserted_at],
              # the list only needs to know whether a certificate can be downloaded again
              select_merge: %{p12: nil, password: nil, kept?: not is_nil(c.p12)}
            )
        ]
    )
  end

  def create_group(name), do: %Group{} |> Group.changeset(%{name: name}) |> PlatformRepo.insert()

  def delete_group(id) do
    case PlatformRepo.get(Group, id) do
      nil -> :ok
      group -> {:ok, _} = PlatformRepo.delete(group)
    end

    :ok
  end

  @doc """
  The options for `issue/3`, checked: `{:ok, %{password:, days:, label:}}` or
  `{:error, message}`. A blank password means "generate one"; a blank expiry means a year.
  """
  def issue_options(params \\ %{}) do
    params = Map.new(params, fn {k, v} -> {to_string(k), v} end)
    password = params["password"] |> to_string() |> String.trim()
    label = params["label"] |> to_string() |> String.trim()
    # dates are the office's: a certificate made to expire on a day is still valid all
    # of that (local) day's working hours — it lapses at the time of day it was issued
    today = AskDrive.Clock.local_today()

    with {:ok, expires_on} <- parse_expiry(params["expires_on"], today),
         :ok <- check_password(password),
         :ok <- check_expiry(expires_on, today),
         :ok <- check_label(label) do
      {:ok,
       %{
         password: if(password == "", do: nil, else: password),
         days: Date.diff(expires_on, today),
         label: if(label == "", do: nil, else: label)
       }}
    end
  end

  defp parse_expiry(%Date{} = date, _today), do: {:ok, date}
  defp parse_expiry(blank, today) when blank in [nil, ""], do: {:ok, Date.add(today, @cert_days)}

  defp parse_expiry(text, _today) when is_binary(text) do
    case Date.from_iso8601(String.trim(text)) do
      {:ok, date} -> {:ok, date}
      _ -> {:error, "有効期限の日付が正しくありません。"}
    end
  end

  # ASCII only: every OS's importer takes it the same way (non-ASCII .p12 passwords are
  # encoded differently by Windows, macOS and OpenSSL)
  defp check_password(""), do: :ok

  defp check_password(password) do
    if String.length(password) in 8..64 and password =~ ~r/\A[\x21-\x7e]+\z/,
      do: :ok,
      else: {:error, "パスワードは 8〜64 文字の半角英数字・記号（空白なし）で入力してください。"}
  end

  defp check_expiry(expires_on, today) do
    latest = latest_expiry()

    cond do
      Date.compare(expires_on, today) != :gt ->
        {:error, "有効期限は明日以降の日付を指定してください。"}

      latest && Date.compare(expires_on, latest) == :gt ->
        {:error, "有効期限は #{latest}（AskDrive の認証局の期限）までの日付を指定してください。"}

      true ->
        :ok
    end
  end

  defp check_label(label) do
    if String.length(label) <= 40, do: :ok, else: {:error, "メモは 40 文字以内で入力してください。"}
  end

  @doc "The last day a certificate can be valid: the CA's own expiry (nil before the CA exists)."
  def latest_expiry do
    case File.read(ca_cert_path()) do
      {:ok, pem} ->
        pem |> validity() |> elem(1) |> AskDrive.Clock.to_local() |> NaiveDateTime.to_date()

      _ ->
        nil
    end
  end

  @doc """
  Issues a certificate for the group: `{:ok, %{cert:, p12:, password:, filename:}}` or
  `{:error, message}` for bad options (see `issue_options/1`). The certificate is named
  "AskDrive（group）" — or "AskDrive（group / label）" — which is what browsers' pickers
  and the keychain show. The `.p12` and its password are kept encrypted for downloading
  again (F-1409).
  """
  def issue(%Group{} = group, issued_by, params \\ %{}) do
    with {:ok, opts} <- issue_options(params), do: do_issue(group, issued_by, opts)
  end

  defp do_issue(group, issued_by, opts) do
    ensure_ca!()
    tmp = Path.join(System.tmp_dir!(), "askdrive_cc_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    serial = :crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower)
    password = opts.password || password()
    name = display_name(group.name, opts.label)
    path = &Path.join(tmp, &1)

    try do
      File.write!(
        path.("ext.cnf"),
        "basicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=clientAuth\n"
      )

      openssl!(
        ~w(req -new -newkey rsa:2048 -nodes -utf8) ++
          [
            "-keyout",
            path.("key.pem"),
            "-out",
            path.("req.csr"),
            "-subj",
            "/CN=#{subj_escape(name)}/O=AskDrive"
          ]
      )

      openssl!(
        ["x509", "-req", "-in", path.("req.csr"), "-CA", ca_cert_path(), "-CAkey", ca_key_path()] ++
          ["-set_serial", "0x" <> serial, "-days", to_string(opts.days), "-sha256"] ++
          ["-extfile", path.("ext.cnf"), "-out", path.("cert.pem")]
      )

      # 3DES / SHA-1: the encryption iOS, older macOS and Windows can import. The password
      # goes through the environment, not the command line (visible in `ps`).
      openssl!(
        ["pkcs12", "-export", "-inkey", path.("key.pem"), "-in", path.("cert.pem")] ++
          ["-certfile", ca_cert_path(), "-name", name] ++
          [
            "-passout",
            "env:ASKDRIVE_P12_PASS",
            "-keypbe",
            "PBE-SHA1-3DES",
            "-certpbe",
            "PBE-SHA1-3DES"
          ] ++
          ["-macalg", "sha1", "-out", path.("cert.p12")],
        [{"ASKDRIVE_P12_PASS", password}]
      )

      {not_before, not_after} = validity(File.read!(path.("cert.pem")))
      p12 = File.read!(path.("cert.p12"))

      {:ok, cert} =
        PlatformRepo.insert(%Cert{
          group_id: group.id,
          serial: serial,
          label: opts.label,
          p12: p12,
          password: password,
          not_before: not_before,
          not_after: not_after,
          issued_by: issued_by
        })

      {:ok, %{cert: cert, p12: p12, password: password, filename: filename(cert)}}
    after
      File.rm_rf!(tmp)
    end
  end

  @doc "What the certificate is called in browsers' pickers and the keychain."
  def display_name(group_name, nil), do: "AskDrive（#{group_name}）"
  def display_name(group_name, label), do: "AskDrive（#{group_name} / #{label}）"

  # `-subj` separates fields with "/" and "=", so escape those (and the escape itself)
  defp subj_escape(text), do: String.replace(text, ["\\", "/", "=", "+"], &("\\" <> &1))

  defp filename(%Cert{} = cert),
    do: "askdrive-#{DateTime.to_date(cert.inserted_at)}-#{String.slice(cert.serial, 0, 8)}.p12"

  @doc """
  Makes an issued certificate downloadable again (F-1409): `{:ok, %{token:, password:,
  cert:}}`, or `{:error, reason}` — `:not_kept` (issued before certificates were kept),
  `:revoked`, `:expired` or `:not_found`.
  """
  def redownload(cert_id, by) do
    cert = PlatformRepo.one(from c in Cert, where: c.id == ^cert_id, preload: :group)

    cond do
      is_nil(cert) ->
        {:error, :not_found}

      cert.revoked_at ->
        {:error, :revoked}

      cert.not_after && DateTime.compare(cert.not_after, now()) == :lt ->
        {:error, :expired}

      is_nil(cert.p12) or is_nil(cert.password) ->
        {:error, :not_kept}

      true ->
        Logger.warning(
          "ClientCerts: certificate #{cert.serial} (#{cert.group.name}) made downloadable again by #{by}"
        )

        token = stash_download(cert.p12, filename(cert), cert.group.name, cert.serial)
        {:ok, %{token: token, password: cert.password, cert: cert}}
    end
  end

  def revoke(cert_id, revoked_by) do
    case PlatformRepo.get(Cert, cert_id) do
      nil ->
        {:error, :not_found}

      cert ->
        cert
        |> Ecto.Changeset.change(revoked_at: now(), revoked_by: revoked_by)
        |> PlatformRepo.update()
    end
  end

  # --- Checking a peer certificate -------------------------------------------------------

  @doc """
  What the certificate a browser presented (DER, or nil) amounts to:
  `{:ok, cert}` (valid; with its group), `:none`, `:unknown` (not issued here),
  `:revoked` or `:expired`.
  """
  def check(nil), do: :none

  def check(der) when is_binary(der) do
    serial = serial_of(der)
    cert = serial && PlatformRepo.one(from c in Cert, where: c.serial == ^serial, preload: :group)

    cond do
      is_nil(cert) -> :unknown
      cert.revoked_at -> :revoked
      cert.not_after && DateTime.compare(cert.not_after, DateTime.utc_now()) == :lt -> :expired
      true -> {:ok, cert}
    end
  rescue
    _ -> :unknown
  end

  @doc "Remembers the certificate was used (at most once a minute per certificate)."
  def seen(%Cert{} = cert) do
    if is_nil(cert.last_seen_at) or DateTime.diff(DateTime.utc_now(), cert.last_seen_at) > 60 do
      PlatformRepo.update_all(from(c in Cert, where: c.id == ^cert.id),
        set: [last_seen_at: now()]
      )
    end

    :ok
  end

  @doc "Monitor mode: remembers whether the user came with a certificate (at most every 10 min)."
  def note_user(%AskDrive.Accounts.User{id: id} = user, with_cert?) when id > 0 do
    field = if with_cert?, do: :client_cert_seen_at, else: :no_client_cert_seen_at
    last = Map.get(user, field)

    if is_nil(last) or DateTime.diff(DateTime.utc_now(), last) > 600 do
      PlatformRepo.update_all(
        from(u in AskDrive.Accounts.User, where: u.id == ^id),
        set: [{field, now()}]
      )
    end

    :ok
  end

  def note_user(_user, _with_cert?), do: :ok

  @doc "Users who came without a certificate lately and not with one since (monitor mode)."
  def users_without_cert do
    PlatformRepo.all(
      from u in AskDrive.Accounts.User,
        where:
          not is_nil(u.no_client_cert_seen_at) and
            (is_nil(u.client_cert_seen_at) or u.client_cert_seen_at < u.no_client_cert_seen_at),
        order_by: [desc: u.no_client_cert_seen_at],
        limit: 100
    )
  end

  defp serial_of(der) do
    {:OTPCertificate, tbs, _, _} = :public_key.pkix_decode_cert(der, :otp)
    elem(tbs, 2) |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(24, "0")
  end

  defp validity(pem) do
    [{:Certificate, der, _} | _] = :public_key.pem_decode(pem)
    {:OTPCertificate, tbs, _, _} = :public_key.pkix_decode_cert(der, :otp)
    {:Validity, from, to} = elem(tbs, 5)
    {asn1_time(from), asn1_time(to)}
  end

  defp asn1_time({:utcTime, t}), do: parse_time("20" <> to_string(t))
  defp asn1_time({:generalTime, t}), do: parse_time(to_string(t))

  defp parse_time(
         <<y::binary-4, mo::binary-2, d::binary-2, h::binary-2, mi::binary-2, s::binary-2,
           _::binary>>
       ) do
    {:ok, dt} =
      NaiveDateTime.new(
        String.to_integer(y),
        String.to_integer(mo),
        String.to_integer(d),
        String.to_integer(h),
        String.to_integer(mi),
        String.to_integer(s)
      )

    DateTime.from_naive!(dt, "Etc/UTC")
  end

  # --- Downloads, per OS ------------------------------------------------------------------

  @formats ~w(windows macos ios android)

  def formats, do: @formats

  @doc """
  Keeps an issued certificate for downloading within 10 minutes (an administrator fetches
  the form each OS installs most easily); returns the token.
  """
  def stash_download(p12, filename, group_name \\ "AskDrive", serial \\ nil) do
    token = :crypto.strong_rand_bytes(18) |> Base.url_encode64(padding: false)
    until = System.monotonic_time(:second) + 600

    :persistent_term.put(
      {__MODULE__, :download, token},
      {p12, filename, group_name, serial, until}
    )

    token
  end

  @doc """
  The stashed certificate in the form for `format` — `{:ok, body, filename, content_type}`
  or `:error` (unknown or expired). All keep the key in the user's own store, so no
  administrator rights on the device are needed:

    * `windows` — `.pfx` (opens the import wizard; "Current User" store)
    * `macos` / `android` — `.p12` (login keychain / "user certificates")
    * `ios` — `.mobileconfig`: a profile carrying the .p12, installed with the device
      passcode; the certificate's password is asked for during installation
  """
  def take_download(token, format \\ "macos") do
    key = {__MODULE__, :download, token}

    case :persistent_term.get(key, nil) do
      {p12, filename, group, serial, until} ->
        if System.monotonic_time(:second) <= until do
          base = Path.rootname(filename)

          case format do
            "windows" ->
              {:ok, p12, base <> ".pfx", "application/x-pkcs12"}

            "ios" ->
              {:ok, mobileconfig(p12, group, serial), base <> ".mobileconfig",
               "application/x-apple-aspen-config"}

            _ ->
              {:ok, p12, base <> ".p12", "application/x-pkcs12"}
          end
        else
          :persistent_term.erase(key)
          :error
        end

      _ ->
        :error
    end
  end

  # An (unsigned) configuration profile with the .p12 as a pkcs12 payload, without the
  # password, so iOS asks for it while installing
  defp mobileconfig(p12, group, serial) do
    id = serial || :crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower)
    esc = &(&1 |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string())

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>PayloadContent</key>
      <array>
        <dict>
          <key>PayloadType</key><string>com.apple.security.pkcs12</string>
          <key>PayloadVersion</key><integer>1</integer>
          <key>PayloadIdentifier</key><string>askdrive.client-cert.#{id}.pkcs12</string>
          <key>PayloadUUID</key><string>#{uuid()}</string>
          <key>PayloadDisplayName</key><string>#{esc.("AskDrive " <> group)}</string>
          <key>PayloadCertificateFileName</key><string>askdrive.p12</string>
          <key>PayloadContent</key>
          <data>#{Base.encode64(p12)}</data>
        </dict>
      </array>
      <key>PayloadDisplayName</key><string>#{esc.("AskDrive 証明書（" <> group <> "）")}</string>
      <key>PayloadDescription</key><string>AskDrive にアクセスするための電子証明書です。インストール中に、別途伝えられたパスワードを入力してください。</string>
      <key>PayloadIdentifier</key><string>askdrive.client-cert.#{id}</string>
      <key>PayloadType</key><string>Configuration</string>
      <key>PayloadUUID</key><string>#{uuid()}</string>
      <key>PayloadVersion</key><integer>1</integer>
    </dict>
    </plist>
    """
  end

  defp uuid do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)
    c = Bitwise.bor(Bitwise.band(c, 0x0FFF), 0x4000)
    d = Bitwise.bor(Bitwise.band(d, 0x3FFF), 0x8000)

    [a, b, c, d, e]
    |> Enum.zip([8, 4, 4, 4, 12])
    |> Enum.map_join("-", fn {v, w} ->
      v |> Integer.to_string(16) |> String.pad_leading(w, "0")
    end)
    |> String.upcase()
  end

  # --- Helpers ----------------------------------------------------------------------------

  # 16 characters from an alphabet without look-alikes, to read out or type
  defp password do
    alphabet = ~c"ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789"
    for _ <- 1..16, into: "", do: <<Enum.random(alphabet)>>
  end

  defp openssl!(args, env \\ []) do
    case System.cmd("openssl", args, stderr_to_stdout: true, env: env) do
      {_, 0} -> :ok
      {out, code} -> raise "openssl #{hd(args)} failed (#{code}): #{String.slice(out, 0, 300)}"
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
