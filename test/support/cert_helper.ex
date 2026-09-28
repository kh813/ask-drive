defmodule AskDrive.CertHelper do
  @moduledoc "Generates throwaway CA / server certificates with openssl for SSL tests."

  def tmp_dir do
    dir = Path.join(System.tmp_dir!(), "askdrive_cert_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    dir
  end

  @doc "A CA and a server certificate for `names` signed by it; returns PEM strings."
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

    run!(
      dir,
      ~w(x509 -req -in leaf.csr -CA ca.pem -CAkey ca.key -CAcreateserial -out leaf.pem -days #{days} -extfile ext.cnf)
    )

    read = &File.read!(Path.join(dir, &1))
    %{cert: read.("leaf.pem"), key: read.("leaf.key"), chain: read.("ca.pem"), dir: dir}
  end

  defp run!(dir, args) do
    {out, code} = System.cmd("openssl", args, cd: dir, stderr_to_stdout: true)
    if code != 0, do: raise("openssl failed: #{out}")
  end
end
