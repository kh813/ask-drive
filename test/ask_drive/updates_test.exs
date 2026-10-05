defmodule AskDrive.UpdatesTest do
  use AskDrive.DataCase, async: false

  alias AskDrive.{Settings, Updates}

  setup do
    on_exit(fn -> Application.delete_env(:ask_drive, :update_req_options) end)
  end

  defp stub_github(fun), do: Application.put_env(:ask_drive, :update_req_options, plug: fun)

  test "versions compare as versions, with or without a v" do
    assert Updates.newer?("v0.1.30", "0.1.29")
    assert Updates.newer?("0.2.0", "v0.1.99")
    refute Updates.newer?("0.1.29", "0.1.29")
    refute Updates.newer?("0.1.9", "0.1.29")
    refute Updates.newer?("garbage", "0.1.29")
  end

  test "check: the latest release from GitHub, kept in the platform settings (F-1501)" do
    stub_github(fn conn ->
      Req.Test.json(conn, %{
        "tag_name" => "v99.0.0",
        "body" => "- いろいろ直しました",
        "html_url" => "https://github.com/kh813/ask-drive/releases/tag/v99.0.0"
      })
    end)

    assert {:ok, %{version: "99.0.0", notes: "- いろいろ直しました"}} = Updates.check()
    setting = Settings.platform_setting!()
    assert setting.update_latest_version == "99.0.0"
    assert setting.update_checked_at
    assert Updates.available_version(setting) == "99.0.0"
  end

  test "check: GitHub unreachable or failing is reported, not raised" do
    stub_github(fn conn -> Plug.Conn.send_resp(conn, 503, "busy") end)
    assert {:error, message} = Updates.check()
    assert message =~ "503"
  end

  test "the nightly check is due once per night window, when switched on (F-1504)" do
    setting = Settings.platform_setting!()
    night = ~N[2026-10-06 00:30:00]

    assert Updates.nightly_check_due?(%{setting | update_checked_at: nil}, night)

    refute Updates.nightly_check_due?(
             %{setting | update_checked_at: nil},
             ~N[2026-10-06 12:00:00]
           )

    refute Updates.nightly_check_due?(
             %{setting | update_check_enabled: false, update_auto_apply: false},
             night
           )

    checked = AskDrive.Clock.local_to_utc(~N[2026-10-06 00:05:00])
    refute Updates.nightly_check_due?(%{setting | update_checked_at: checked}, night)

    yesterday = AskDrive.Clock.local_to_utc(~N[2026-10-05 00:05:00])
    assert Updates.nightly_check_due?(%{setting | update_checked_at: yesterday}, night)
  end
end
