defmodule AskDrive.LLM.QuotaLimiterTest do
  @moduledoc "Cloud generations at once, per API key, shared by the desks using it (F-841)."
  use ExUnit.Case, async: false

  alias AskDrive.LLM.QuotaLimiter

  setup do
    server = start_supervised!({QuotaLimiter, name: nil})
    %{server: server}
  end

  # `n` generations of `key` (each holding its slot until told to go), started at once
  defp start(server, key, limit, n) do
    test = self()

    for _ <- 1..n do
      spawn(fn ->
        QuotaLimiter.run(
          key,
          limit,
          fn ->
            send(test, {:started, key, self()})

            receive do
              :go -> :ok
            end
          end,
          server
        )
      end)
    end
  end

  defp started(count) do
    for _ <- 1..count do
      assert_receive {:started, _key, pid}
      pid
    end
  end

  test "desks on the same key share its slots; another key has its own", %{server: server} do
    start(server, "key-a", 2, 3)
    start(server, "key-b", 2, 2)
    assert_receive {:started, "key-a", a}
    assert_receive {:started, "key-a", _}
    assert_receive {:started, "key-b", _}
    assert_receive {:started, "key-b", _}
    refute_receive {:started, _, _}, 50

    assert %{running: 2, waiting: 1} = QuotaLimiter.info("key-a", server)
    assert %{running: 2, waiting: 0} = QuotaLimiter.info("key-b", server)

    # one of key-a's finishes: the waiting one gets its slot
    send(a, :go)
    assert_receive {:started, "key-a", _}
  end

  test "the smallest limit asked for is the key's", %{server: server} do
    start(server, "key", 4, 1)
    started(1)
    start(server, "key", 1, 2)
    refute_receive {:started, _, _}, 50
    assert %{running: 1, waiting: 2} = QuotaLimiter.info("key", server)
  end

  test "a rate limit halves the slots; they come back a minute later", %{server: server} do
    Application.put_env(:ask_drive, :quota_recover_ms, 0)
    on_exit(fn -> Application.delete_env(:ask_drive, :quota_recover_ms) end)

    test = self()

    spawn(fn ->
      QuotaLimiter.run(
        "key",
        4,
        fn ->
          QuotaLimiter.rate_limited()
          send(test, :limited)
        end,
        server
      )
    end)

    assert_receive :limited
    _ = :sys.get_state(server)
    # recovers one slot per (here: zero-length) minute, back to no cap once it reaches 4
    start(server, "key", 4, 4)
    started(4)
    assert %{running: 4, cap: nil} = QuotaLimiter.info("key", server)
  end

  test "a rate limit caps the slots until it recovers", %{server: server} do
    test = self()

    spawn(fn ->
      QuotaLimiter.run(
        "key",
        4,
        fn ->
          QuotaLimiter.rate_limited()
          send(test, :limited)

          receive do
            :go -> :ok
          end
        end,
        server
      )
    end)

    assert_receive :limited
    _ = :sys.get_state(server)
    assert %{cap: 2} = QuotaLimiter.info("key", server)

    start(server, "key", 4, 3)
    started(1)
    refute_receive {:started, _, _}, 50
  end

  test "a holder that dies gives its slot back", %{server: server} do
    start(server, "key", 1, 2)
    [holder] = started(1)
    Process.exit(holder, :kill)
    assert_receive {:started, _, _}
  end

  test "rate_limited/0 outside run/3 does nothing" do
    assert :ok = QuotaLimiter.rate_limited()
  end
end
