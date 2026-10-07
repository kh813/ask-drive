defmodule AskDrive.Drive.ClientTest do
  use AskDrive.DataCase, async: false

  alias AskDrive.Drive.Client

  setup do
    {:ok, _} = AskDrive.Accounts.save_tokens(%{access_token: "token", refresh_token: "refresh"})
    on_exit(fn -> Application.delete_env(:ask_drive, :drive_req_options) end)
    %{calls: :counters.new(1, [])}
  end

  # Answers each call with fun.(n), n counting from 1. An exception raised in a plug comes out
  # of Req the way Finch's does when a pooled connection holds an earlier request's response.
  defp stub_drive(calls, fun) do
    Application.put_env(:ask_drive, :drive_req_options,
      plug: fn conn ->
        :counters.add(calls, 1, 1)
        fun.(conn, :counters.get(calls, 1))
      end
    )
  end

  defp finch_stale_response!, do: raise(CaseClauseError, term: {:status, make_ref(), 200})

  describe "a request that raises inside the HTTP client" do
    @describetag :capture_log

    test "is retried for a file export, not failed", %{calls: calls} do
      stub_drive(calls, fn conn, n ->
        if n == 1, do: finch_stale_response!(), else: Plug.Conn.send_resp(conn, 200, "本文")
      end)

      assert {:ok, "本文"} = Client.export("file-id", "text/plain")
      assert :counters.get(calls, 1) == 2
    end

    test "is retried for a JSON API call", %{calls: calls} do
      stub_drive(calls, fn conn, n ->
        if n == 1,
          do: finch_stale_response!(),
          else: Req.Test.json(conn, %{"id" => "file-id", "name" => "資料"})
      end)

      assert {:ok, %{"name" => "資料"}} = Client.get_metadata("file-id")
      assert :counters.get(calls, 1) == 2
    end

    test "gives up after the retries with an error the batch log can show", %{calls: calls} do
      stub_drive(calls, fn _conn, _n -> finch_stale_response!() end)

      assert {:error, {:exception, message}} = Client.download("file-id")
      assert message =~ "no case clause matching"
      assert :counters.get(calls, 1) == 5
    end
  end

  test "a 404 is returned at once, not retried", %{calls: calls} do
    stub_drive(calls, fn conn, _n -> Plug.Conn.send_resp(conn, 404, "not found") end)

    assert {:error, "HTTP 404" <> _} = Client.export("file-id", "text/plain")
    assert :counters.get(calls, 1) == 1
  end

  @tag :capture_log
  test "a 503 is retried as before", %{calls: calls} do
    stub_drive(calls, fn conn, n ->
      if n == 1,
        do: Plug.Conn.send_resp(conn, 503, "busy"),
        else: Plug.Conn.send_resp(conn, 200, "本文")
    end)

    assert {:ok, "本文"} = Client.export("file-id", "text/plain")
    assert :counters.get(calls, 1) == 2
  end
end
