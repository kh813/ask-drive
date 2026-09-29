defmodule AskDrive.Accounts.LoginThrottleTest do
  use AskDrive.DataCase, async: false
  alias AskDrive.Accounts.LoginThrottle

  @t0 ~U[2026-09-29 10:00:00Z]
  defp env(key),
    do: %{key: key, ip: "10.0.0.1", user_agent: "Mozilla/5.0 (Windows NT 10.0) Chrome/131.0"}

  defp at(seconds), do: DateTime.add(@t0, seconds)

  test "account: 5 failures within 5 minutes lock it for 15 minutes" do
    for i <- 0..3,
        do: LoginThrottle.record_failure("a@example.com", env("device:#{i}"), "x", at(i * 60))

    assert LoginThrottle.check("a@example.com", "device:9", at(240)) == :ok
    assert LoginThrottle.remaining("a@example.com", at(240)) == 1

    LoginThrottle.record_failure("A@example.com", env("device:4"), "x", at(240))
    assert {:locked, until, :account} = LoginThrottle.check("a@example.com", "device:9", at(241))
    assert until == at(240 + 15 * 60)
    assert LoginThrottle.check("a@example.com", "device:9", at(240 + 15 * 60 + 1)) == :ok

    # another account is unaffected
    assert LoginThrottle.check("b@example.com", "device:9", at(241)) == :ok
  end

  test "account: 5 failures spread over more than 5 minutes don't lock" do
    for i <- 0..4,
        do: LoginThrottle.record_failure("a@example.com", env("device:x"), "x", at(i * 90))

    assert LoginThrottle.check("a@example.com", "device:y", at(360)) == :ok
  end

  test "environment: 10 failures within 24 hours (any accounts) lock it for 24 hours" do
    for i <- 0..9,
        do:
          LoginThrottle.record_failure("u#{i}@example.com", env("device:bad"), "x", at(i * 3600))

    assert {:locked, until, :env} =
             LoginThrottle.check("new@example.com", "device:bad", at(9 * 3600 + 1))

    assert until == at(9 * 3600 + 24 * 3600)

    # another browser behind the same address (office NAT) is not locked
    assert LoginThrottle.check("new@example.com", "device:colleague", at(9 * 3600 + 1)) == :ok
  end

  test "environment: failures older than 24 hours don't count" do
    for i <- 0..8,
        do: LoginThrottle.record_failure("u#{i}@example.com", env("device:e"), "x", at(i))

    LoginThrottle.record_failure("z@example.com", env("device:e"), "x", at(25 * 3600))
    assert LoginThrottle.check("z2@example.com", "device:e", at(25 * 3600 + 1)) == :ok
  end

  test "an administrator lifts a lock, and the failures behind it are forgotten" do
    for i <- 0..4, do: LoginThrottle.record_failure("a@example.com", env("device:#{i}"), "x")
    assert [lock] = LoginThrottle.active_locks()
    assert lock.scope == "account" and lock.email == "a@example.com"

    assert {:ok, _} = LoginThrottle.unlock(lock.id)
    assert LoginThrottle.check("a@example.com", "device:9") == :ok
    assert LoginThrottle.remaining("a@example.com") == 5
  end

  test "environment key: the device cookie, else a hash of address + User-Agent + language" do
    assert LoginThrottle.env_key("abc", "1.2.3.4", "UA", "ja") == "device:abc"
    a = LoginThrottle.env_key(nil, "1.2.3.4", "UA", "ja")
    assert "headers:" <> _ = a
    assert a == LoginThrottle.env_key("", "1.2.3.4", "UA", "ja")
    refute a == LoginThrottle.env_key(nil, "1.2.3.4", "UA2", "ja")
  end

  test "describe_user_agent" do
    assert LoginThrottle.describe_user_agent(
             "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/131.0.0.0 Safari/537.36 Edg/131.0"
           ) == "Edge 131 / Windows"

    assert LoginThrottle.describe_user_agent(
             "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Version/17.4 Safari/605.1.15"
           ) == "Safari 17 / macOS"
  end
end
