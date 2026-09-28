defmodule AskDrive.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # HTTPS (spec 6.10): make sure a certificate exists and point the endpoint at it before
    # the endpoint starts; the HTTP ports then only redirect.
    AskDrive.SSL.configure_endpoint!()

    children =
      [
        AskDriveWeb.Telemetry,
        AskDrive.Repo,
        {Ecto.Migrator,
         repos: Application.fetch_env!(:ask_drive, :ecto_repos), skip: skip_migrations?()},
        {DNSCluster, query: Application.get_env(:ask_drive, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: AskDrive.PubSub},
        {Oban, Application.fetch_env!(:ask_drive, Oban)},
        AskDrive.LLM.Semaphore,
        AskDrive.Drive.ServiceAccount,
        AskDrive.HealthCheck,
        AskDrive.Runtime.Mode,
        AskDrive.LLM.OllamaModels,
        # Start to serve requests, typically the last entry
        AskDriveWeb.Endpoint
      ] ++ https_redirect_servers()

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: AskDrive.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    AskDriveWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  # One redirect-only listener per HTTP port (4080, and 4000 during the transition)
  defp https_redirect_servers do
    if AskDrive.SSL.enabled?() and Application.get_env(:ask_drive, AskDriveWeb.Endpoint)[:server] do
      for port <- AskDrive.SSL.redirect_ports() do
        Supervisor.child_spec(
          {Bandit, plug: AskDriveWeb.HTTPSRedirect, port: port, ip: {0, 0, 0, 0, 0, 0, 0, 0}},
          id: {:https_redirect, port}
        )
      end
    else
      []
    end
  end

  defp skip_migrations?() do
    # By default, sqlite migrations are run when using a release
    System.get_env("RELEASE_NAME") == nil
  end
end
