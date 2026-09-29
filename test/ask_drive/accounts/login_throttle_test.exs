defmodule AskDrive.Accounts.LoginThrottleTest do
  use AskDrive.DataCase, async: false
  alias AskDrive.Accounts.LoginThrottle

  test "5 failures lock the account; the address locks after 20 across accounts; success clears" do
    for _ <- 1..4, do: LoginThrottle.record_failure("a@example.com", "10.0.0.1", "x")
    assert LoginThrottle.check("A@example.com", "10.0.0.9") == :ok
    assert LoginThrottle.remaining("a@example.com") == 1

    LoginThrottle.record_failure("a@example.com", "10.0.0.1", "x")
    assert {:locked, until} = LoginThrottle.check("a@example.com", "10.0.0.9")
    assert DateTime.diff(until, DateTime.utc_now()) in 890..900

    # another account from another address is unaffected
    assert LoginThrottle.check("b@example.com", "10.0.0.9") == :ok

    for i <- 1..15, do: LoginThrottle.record_failure("u#{i}@example.com", "10.0.0.1", "x")
    assert {:locked, _} = LoginThrottle.check("new@example.com", "10.0.0.1")

    LoginThrottle.clear("a@example.com")
    assert LoginThrottle.check("a@example.com", "10.0.0.9") == :ok
  end

  test "failures older than the window don't count" do
    for _ <- 1..5, do: LoginThrottle.record_failure("a@example.com", "10.0.0.1", "x")
    later = DateTime.add(DateTime.utc_now(), 16 * 60)
    assert LoginThrottle.check("a@example.com", "10.0.0.2", later) == :ok
  end
end
