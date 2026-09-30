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
  def mode do
    key = {__MODULE__, :mode}
    stat = {mode_file(), File.stat(mode_file())}

    case :persistent_term.get(key, nil) do
      {^stat, mode} ->
        mode

      _ ->
        mode =
          with {:ok, json} <- File.read(mode_file()),
               {:ok, %{"mode" => m}} when m in @modes <- Jason.decode(json),
               do: m,
               else: (_ -> "off")

        :persistent_term.put(key, {stat, mode})
        mode
    end
  end

  @doc "Whether the HTTPS listener must ask for certificates (restart when this changes)."
  def request_certs?, do: mode() != "off"

  @doc "Sets the mode. Returns `{:ok, restart_needed?}` (asking for certificates starts / stops)."
  def set_mode(mode) when mode in @modes do
    before = request_certs?()
    if mode != "off", do: ensure_ca!()
    File.mkdir_p!(Path.dirname(mode_file()))
    File.write!(mode_file(), Jason.encode!(%{"mode" => mode}))
    :persistent_term.erase({__MODULE__, :mode})
    {:ok, before != request_certs?()}
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
        preload: [certs: ^from(c in Cert, order_by: [desc: c.inserted_at])]
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
  Issues a certificate for the group: `{:ok, %{cert:, p12:, password:, filename:}}`. The
  key exists only inside the `.p12`, which is handed out once; nothing of it is kept.
  """
  def issue(%Group{} = group, issued_by) do
    ensure_ca!()
    tmp = Path.join(System.tmp_dir!(), "askdrive_cc_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    serial = :crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower)
    password = password()
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
            "/CN=#{group.name}/O=AskDrive"
          ]
      )

      openssl!(
        ["x509", "-req", "-in", path.("req.csr"), "-CA", ca_cert_path(), "-CAkey", ca_key_path()] ++
          ["-set_serial", "0x" <> serial, "-days", to_string(@cert_days), "-sha256"] ++
          ["-extfile", path.("ext.cnf"), "-out", path.("cert.pem")]
      )

      # 3DES / SHA-1: the encryption iOS, older macOS and Windows can import
      openssl!(
        ["pkcs12", "-export", "-inkey", path.("key.pem"), "-in", path.("cert.pem")] ++
          ["-certfile", ca_cert_path(), "-name", "AskDrive #{group.name}"] ++
          [
            "-passout",
            "pass:" <> password,
            "-keypbe",
            "PBE-SHA1-3DES",
            "-certpbe",
            "PBE-SHA1-3DES"
          ] ++
          ["-macalg", "sha1", "-out", path.("cert.p12")]
      )

      {not_before, not_after} = validity(File.read!(path.("cert.pem")))

      {:ok, cert} =
        PlatformRepo.insert(%Cert{
          group_id: group.id,
          serial: serial,
          not_before: not_before,
          not_after: not_after,
          issued_by: issued_by
        })

      {:ok,
       %{
         cert: cert,
         p12: File.read!(path.("cert.p12")),
         password: password,
         filename: "askdrive-#{Date.utc_today()}-#{String.slice(serial, 0, 8)}.p12"
       }}
    after
      File.rm_rf!(tmp)
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

  # --- One-time downloads -----------------------------------------------------------------

  @doc "Keeps an issued `.p12` for one download within 10 minutes; returns its token."
  def stash_download(p12, filename) do
    token = :crypto.strong_rand_bytes(18) |> Base.url_encode64(padding: false)

    :persistent_term.put(
      {__MODULE__, :download, token},
      {p12, filename, System.monotonic_time(:second) + 600}
    )

    token
  end

  @doc "Takes (and forgets) a stashed download: `{:ok, p12, filename}` or `:error`."
  def take_download(token) do
    key = {__MODULE__, :download, token}

    case :persistent_term.get(key, nil) do
      {p12, filename, until} ->
        :persistent_term.erase(key)
        if System.monotonic_time(:second) <= until, do: {:ok, p12, filename}, else: :error

      _ ->
        :error
    end
  end

  # --- Helpers ----------------------------------------------------------------------------

  # 16 characters from an alphabet without look-alikes, to read out or type
  defp password do
    alphabet = ~c"ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789"
    for _ <- 1..16, into: "", do: <<Enum.random(alphabet)>>
  end

  defp openssl!(args) do
    case System.cmd("openssl", args, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, code} -> raise "openssl #{hd(args)} failed (#{code}): #{String.slice(out, 0, 300)}"
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
