defmodule AskDrive.CertHelper do
  @moduledoc "Generates throwaway CA / server certificates with openssl for SSL tests."

  def tmp_dir do
    # unique_integer restarts per VM, so add randomness and clear leftovers of earlier runs
    suffix = "#{System.unique_integer([:positive])}_#{:rand.uniform(1_000_000_000)}"
    dir = Path.join(System.tmp_dir!(), "askdrive_cert_#{suffix}")
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    dir
  end

  @doc """
  A CA and a server certificate for `names` signed by it; returns PEM strings. `expired: true`
  gives a server certificate whose validity has already ended.
  """
  def ca_signed(names, opts \\ []) do
    dir = tmp_dir()
    days = Keyword.get(opts, :days, 30)

    run!(
      dir,
      ~w(req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.pem -days 30 -subj /CN=TestCA)
    )

    File.write!(
      Path.join(dir, "ext.cnf"),
      "subjectAltName=" <>
        Enum.map_join(names, ",", &"DNS:#{&1}") <> "\nbasicConstraints=CA:FALSE\n"
    )

    run!(
      dir,
      ~w(req -newkey rsa:2048 -nodes -keyout leaf.key -out leaf.csr -subj /CN=#{hd(names)})
    )

    sign =
      ~w(x509 -req -in leaf.csr -CA ca.pem -CAkey ca.key -CAcreateserial -out leaf.pem -extfile ext.cnf)

    if Keyword.get(opts, :expired, false) do
      sign_expired!(dir, sign)
    else
      run!(dir, sign ++ ~w(-days #{days}))
    end

    read = &File.read!(Path.join(dir, &1))
    %{cert: read.("leaf.pem"), key: read.("leaf.key"), chain: read.("ca.pem"), dir: dir}
  end

  # OpenSSL 3.4+ takes explicit dates in the past; older ones (Ubuntu's 3.0) don't, but still
  # accept -days 0 (valid only for "now"), which OpenSSL 4 refuses: then wait past it
  defp sign_expired!(dir, sign) do
    case System.cmd(
           "openssl",
           sign ++ ~w(-not_before 20200101000000Z -not_after 20200102000000Z),
           cd: dir,
           stderr_to_stdout: true
         ) do
      {_out, 0} ->
        :ok

      _ ->
        run!(dir, sign ++ ~w(-days 0))
        Process.sleep(1100)
    end
  end

  defp run!(dir, args) do
    {out, code} = System.cmd("openssl", args, cd: dir, stderr_to_stdout: true)
    if code != 0, do: raise("openssl failed: #{out}")
  end
end
