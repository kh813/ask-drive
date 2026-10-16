defmodule AskDrive.Notify.GoogleChatTest do
  use AskDrive.DataCase, async: false

  alias AskDrive.Notify.GoogleChat
  alias AskDrive.{Settings, Updates}
  alias AskDrive.Updates.Server

  @url "https://chat.googleapis.com/v1/spaces/AAAA/messages?key=k&token=t"

  setup do
    test = self()

    Application.put_env(:ask_drive, :notify_req_options,
      plug: fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test, {:google_chat, conn.request_path, Jason.decode!(body)})
        Req.Test.json(conn, %{"name" => "spaces/AAAA/messages/1"})
      end
    )

    on_exit(fn -> Application.delete_env(:ask_drive, :notify_req_options) end)
  end

  defp set_webhook!(url) do
    {:ok, setting} =
      Settings.update_setting(Settings.platform_setting!(), %{google_chat_webhook_url: url})

    setting
  end

  test "posts the text to the webhook; nothing without one (F-1507)" do
    assert GoogleChat.send_message("hello") == :not_configured
    refute_received {:google_chat, _, _}

    setting = set_webhook!(@url)
    assert GoogleChat.configured?(setting)
    assert :ok = GoogleChat.send_message("hello", setting)
    assert_received {:google_chat, "/v1/spaces/AAAA/messages", %{"text" => "hello"}}
  end

  test "a failure is reported, not raised" do
    setting = set_webhook!(@url)

    Application.put_env(:ask_drive, :notify_req_options,
      plug: fn conn ->
        conn
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(%{"error" => %{"message" => "Invalid token"}})
      end
    )

    assert {:error, message} = GoogleChat.send_message("hello", setting)
    assert message =~ "400" and message =~ "Invalid token"
  end

  test "only a Google Chat webhook URL is accepted, and it is kept when the field is left blank" do
    assert {:error, changeset} =
             Settings.update_setting(Settings.platform_setting!(), %{
               google_chat_webhook_url: "https://example.com/hook"
             })

    assert changeset.errors[:google_chat_webhook_url]

    set_webhook!(@url)

    {:ok, setting} =
      Settings.update_setting(Settings.platform_setting!(), %{"google_chat_webhook_url" => ""})

    assert setting.google_chat_webhook_url == @url
  end

  describe "update notices" do
    setup do
      test = self()
      set_webhook!(@url)
      Application.put_env(:ask_drive, :update_service_check, fn -> true end)
      Application.put_env(:ask_drive, :update_restart_fun, fn -> send(test, :restarted) end)
      Application.put_env(:ask_drive, :update_halt_ms, 0)

      on_exit(fn ->
        for key <- [
              :update_build_command,
              :update_service_check,
              :update_restart_fun,
              :update_halt_ms,
              :update_notify_ms
            ],
            do: Application.delete_env(:ask_drive, key)

        File.rm_rf!(Path.dirname(Server.marker_path()))
        restart_server()
      end)

      File.rm_rf!(Path.dirname(Server.marker_path()))
      restart_server()
      :ok
    end

    defp restart_server do
      :ok = Supervisor.terminate_child(AskDrive.Supervisor, Server)
      {:ok, _} = Supervisor.restart_child(AskDrive.Supervisor, Server)
    end

    test "when an update starts" do
      Application.put_env(:ask_drive, :update_build_command, {"/bin/sh", ["-c", "echo built"]})
      :ok = Updates.start(by: "自動アップデート", to: "9.9.9")

      assert_receive {:google_chat, _, %{"text" => text}}, 2_000
      assert text =~ "アップデートを開始します"
      assert text =~ "→ v9.9.9（自動アップデート）"
      assert_receive :restarted, 5_000
    end

    test "when the build fails" do
      Application.put_env(:ask_drive, :update_build_command, {"/bin/sh", ["-c", "exit 2"]})
      :ok = Updates.start(by: "admin@example.com", to: "9.9.9")

      assert_receive {:google_chat, _, %{"text" => start}}, 2_000
      assert start =~ "開始します"
      assert_receive {:google_chat, _, %{"text" => failed}}, 5_000
      assert failed =~ "失敗しました" and failed =~ "終了コード 2"
    end

    test "when the new version is up after the restart" do
      Application.put_env(:ask_drive, :update_notify_ms, 0)
      File.mkdir_p!(Path.dirname(Server.marker_path()))

      File.write!(
        Server.marker_path(),
        Jason.encode!(%{"from" => "0.0.1", "to" => AskDrive.version(), "by" => "自動アップデート"})
      )

      restart_server()
      assert_receive {:google_chat, _, %{"text" => text}}, 2_000
      assert text =~ "アップデートが完了しました"
      assert text =~ "v0.0.1 → v#{AskDrive.version()} で起動し、正常に稼働しています"
    end

    test "the notices for a restart that didn't switch or isn't healthy" do
      marker = %{"from" => "1.0.0", "to" => "1.1.0", "by" => "自動アップデート"}
      assert Server.boot_notice(marker, "1.0.0", true) =~ "v1.0.0 のままで起動しました"
      assert Server.boot_notice(marker, "1.1.0", false) =~ "正常に稼働していない可能性"
    end
  end
end
