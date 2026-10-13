defmodule AskDriveWeb.GatewayTest do
  @moduledoc "Requests through (and around) the API gateway (spec F-1014)."
  use AskDriveWeb.ConnCase, async: false

  alias AskDrive.{CertHelper, Gateway}

  @secret "s3cret-value-from-infra-0123456789"
  @outside {203, 0, 113, 5}

  setup do
    Application.put_env(:ask_drive, :ssl_dir, CertHelper.tmp_dir())

    on_exit(fn ->
      Application.put_env(:ask_drive, :ssl_dir, nil)
      :persistent_term.erase({Gateway, :cache})
    end)

    :ok
  end

  defp enable!(attrs \\ %{}) do
    {:ok, settings} =
      Gateway.validate(
        Map.merge(%{"secret" => @secret, "public_url" => "https://app.example.com"}, attrs)
      )

    :ok = Gateway.save!(settings)
    :ok = Gateway.set_enabled!(true)
  end

  defp from(conn, ip), do: %{conn | remote_ip: ip}

  test "with no secret set, nothing changes", %{conn: conn} do
    conn = conn |> from(@outside) |> get("/login")
    refute conn.status == 403
  end

  test "around the gateway: 403 for pages and for the LiveView socket", %{conn: conn} do
    enable!()

    conn1 = build_conn() |> from(@outside) |> get("/login")
    assert conn1.status == 403
    assert conn1.resp_body =~ "https://app.example.com/"

    # the socket is dispatched before the endpoint's plugs: the gate must come first
    conn2 = build_conn() |> from(@outside) |> get("/live/longpoll")
    assert conn2.status == 403

    # a wrong secret is no better than none
    conn3 =
      build_conn()
      |> from(@outside)
      |> put_req_header("x-apigw-secret", @secret <> "x")
      |> get("/login")

    assert conn3.status == 403
    _ = conn
  end

  test "through the gateway: public URL, the user's address, a Secure session cookie",
       %{conn: conn} do
    enable!()

    conn =
      conn
      |> from({198, 18, 0, 10})
      |> Map.put(:host, "origin.example.com")
      |> put_req_header("x-apigw-secret", @secret)
      |> put_req_header("x-forwarded-for", "10.9.9.9, 198.51.100.7")
      |> get("/login")

    refute conn.status == 403
    assert {conn.scheme, conn.host, conn.port} == {:https, "app.example.com", 443}
    # the address the gateway appended, not one the browser could have sent before it
    assert conn.remote_ip == {198, 51, 100, 7}

    cookie = conn |> get_resp_header("set-cookie") |> Enum.find(&(&1 =~ "_ask_drive_key"))
    assert cookie =~ ~r/secure/i
    assert cookie =~ ~r/samesite=lax/i
    refute cookie =~ ~r/domain=/i
  end

  test "the server itself and the listed ranges get in without the header" do
    enable!(%{"direct_ranges" => "192.168.0.0/16"})

    refute (build_conn() |> from({127, 0, 0, 1}) |> get("/login")).status == 403
    refute (build_conn() |> from({192, 168, 3, 4}) |> get("/login")).status == 403
    assert (build_conn() |> from({10, 0, 0, 4}) |> get("/login")).status == 403
  end

  test "saving the values doesn't switch the check on (F-206)" do
    {:ok, settings} =
      Gateway.validate(%{"secret" => @secret, "public_url" => "https://app.example.com"})

    :ok = Gateway.save!(settings)
    refute Gateway.enabled?()
    refute (build_conn() |> from(@outside) |> get("/login")).status == 403
  end

  test "gateway-off opens the gate again, keeping the values" do
    enable!()
    :ok = Gateway.disable!()
    refute Gateway.enabled?()
    refute (build_conn() |> from(@outside) |> get("/login")).status == 403
    # the values are kept for next time
    assert Gateway.settings().public_url == "https://app.example.com"
    assert Gateway.settings().secret == @secret
  end

  test "a v0.1.38 file (a secret, no enabled) stays on" do
    File.mkdir_p!(Path.dirname(Gateway.file()))

    File.write!(
      Gateway.file(),
      Jason.encode!(%{"secret" => @secret, "public_url" => "https://a.example.com"})
    )

    assert Gateway.enabled?()
  end

  test "the settings file is readable only by the server's user" do
    enable!()
    assert File.stat!(Gateway.file()).mode |> Bitwise.band(0o777) == 0o600
  end

  describe "validate/1" do
    test "a usable secret and an https origin-less public URL" do
      assert {:error, [msg]} =
               Gateway.validate(%{"secret" => "short", "public_url" => "https://a.example.com"})

      assert msg =~ "16 文字以上"

      # the values can be saved one at a time; switching on needs both
      assert {:ok, partial} = Gateway.validate(%{"secret" => @secret, "public_url" => ""})
      assert Gateway.enable_problems(partial) == ["公開 URL を保存してください"]

      for bad <- ["http://app.example.com", "https://app.example.com/path", "app.example.com"] do
        assert {:error, [msg]} = Gateway.validate(%{"secret" => @secret, "public_url" => bad})
        assert msg =~ "https://app.example.com の形"
      end

      assert {:ok, %{public_url: "https://app.example.com:8443"}} =
               Gateway.validate(%{
                 "secret" => @secret,
                 "public_url" => "https://app.example.com:8443/"
               })
    end

    test "a blank secret keeps the stored one" do
      enable!()

      assert {:ok, %{secret: @secret}} =
               Gateway.validate(%{"secret" => "", "public_url" => "https://app.example.com"})
    end
  end
end
