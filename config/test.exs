import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :ask_drive, AskDrive.Repo,
  database: Path.expand("../ask_drive_test.db", __DIR__),
  pool_size: 5,
  pool: Ecto.Adapters.SQL.Sandbox,
  # each sandboxed test holds SQLite's write lock until it ends, so a writer can wait on a
  # parallel test for a while; the default 5 s was too short on the slower CI runners
  busy_timeout: 30_000

# The suite exercises the real login/elevation flow; tests opt into POC mode explicitly.
config :ask_drive, auth_disabled_by_default: false

# Never let the runtime clock start a real nightly batch in the middle of a test run.
config :ask_drive, auto_nightly_batch: false

# Don't try to pull Ollama models from a test run.
config :ask_drive, auto_pull_models: false

# Apps (spec 6.11): the boot step writes to the platform DB, which is sandboxed in tests;
# app databases created by tests use a plain pool (the SQL sandbox can't own dynamic repos).
config :ask_drive, apps_boot: false, app_repo_opts: [pool: DBConnection.ConnectionPool]

# First-access setup (spec 6.12) would redirect every test request to /setup; its own tests
# switch it back on.
config :ask_drive, setup_check: false

# Disable Oban queues in test
config :ask_drive, Oban, testing: :manual

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :ask_drive, AskDriveWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "BGIB6mScskOk3KC+AA5RiKdjhFgpmdkY2vhIVSwvGmnx19lYz2h0SxvxRaWF/lMi",
  server: false

# In test we don't send emails
config :ask_drive, AskDrive.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Sign-in with LDAP (spec 6.13) talks to a stand-in directory in tests
config :ask_drive, ldap_client: AskDrive.FakeLdap
