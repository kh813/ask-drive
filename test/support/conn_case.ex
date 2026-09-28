defmodule AskDriveWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use AskDriveWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint AskDriveWeb.Endpoint

      use AskDriveWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import AskDriveWeb.ConnCase
    end
  end

  setup tags do
    AskDrive.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  alias AskDrive.Accounts.User
  alias AskDrive.Repo

  @doc """
  Inserts a signed-up user. Every field can be overridden, e.g.
  `user_fixture(admin_eligible: true)`.
  """
  def user_fixture(attrs \\ %{}) do
    attrs =
      Enum.into(attrs, %{
        email: "user#{System.unique_integer([:positive])}@example.com",
        name: "Test User",
        status: "active",
        admin_eligible: false
      })

    {:ok, user} = %User{} |> User.changeset(attrs) |> Repo.insert()
    user
  end

  @doc """
  Puts `user` in the connection's session, as `AskDriveWeb.AuthController` does after a
  successful Google sign-in. Every route that requires authentication reads this same
  session key, so this is the one place a test needs to know its name.
  """
  def log_in_user(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:user_id, user.id)
  end

  @doc """
  Like `log_in_user/2`, but the session is also elevated to administrator — the sudo-style
  state `AskDriveWeb.UserAuth` checks before allowing anything under `/admin` (spec 6.9.1).
  The user must be `admin_eligible` for this to mean anything to the app; callers typically
  pass `user_fixture(admin_eligible: true)`.
  """
  def log_in_admin(conn, user) do
    conn
    |> log_in_user(user)
    |> Plug.Conn.put_session(:admin_elevated_at, System.system_time(:second))
    |> Plug.Conn.put_session(:admin_elevated_user_id, user.id)
  end
end
