defmodule AskDriveWeb.Router do
  use AskDriveWeb, :router

  import AskDriveWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {AskDriveWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # --- Public: sign-in only (spec 6.9) --------------------------------------
  scope "/", AskDriveWeb do
    pipe_through :browser

    get "/login", AuthController, :login
    get "/auth/google", AuthController, :request
    get "/auth/google/callback", AuthController, :callback
    get "/logout", AuthController, :logout
    delete "/logout", AuthController, :logout
  end

  # --- Portal: the list of apps (spec 6.11) --------------------------------
  # Temporary (Phase 17): employee Google login is still blocked, so general users chat
  # without signing in. Admin screens below still require login + elevation.
  scope "/", AskDriveWeb do
    pipe_through :browser

    live_session :portal,
      on_mount: [{AskDriveWeb.UserAuth, :mount_current_user}] do
      live "/", PortalLive
    end
  end

  # --- Elevation prompt: signed in and allowed to try, but not yet elevated --
  scope "/", AskDriveWeb do
    pipe_through [:browser, :require_authenticated_user, :require_admin_eligible]

    get "/admin/elevate", AdminAccessController, :new
    post "/admin/elevate", AdminAccessController, :create
    post "/admin/password", AdminAccessController, :set_password
  end

  # Releasing rights must work for anyone signed in, even after the elevation lapsed.
  scope "/", AskDriveWeb do
    pipe_through [:browser, :require_authenticated_user]

    delete "/admin/elevate", AdminAccessController, :delete
    get "/admin/release", AdminAccessController, :delete
  end

  # --- Elevated sessions only (spec 6.9 F-911) ------------------------------
  scope "/", AskDriveWeb do
    pipe_through [:browser, :require_admin_session]

    # Platform administration: apps, users, SSL, Ollama, the nightly window (spec 6.11)
    live_session :admin,
      on_mount: [{AskDriveWeb.UserAuth, :require_admin_session}] do
      live "/admin", AdminLive, :platform
    end

    # Authorizing and revoking the Drive sync account changes what the whole system reads,
    # so it needs the same elevated session as the settings screen.
    get "/auth/google/drive", AuthController, :request_drive
    get "/auth/google/disconnect", AuthController, :disconnect
    delete "/auth/google", AuthController, :disconnect
  end

  # Other scopes may use custom stacks.
  # scope "/api", AskDriveWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:ask_drive, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: AskDriveWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  # --- Apps (spec 6.11) — last, so the "/:app" catch-all can't shadow any route above ---
  # Reserved slugs (AskDrive.Apps.App.reserved_slugs/0) keep apps from claiming those paths.
  scope "/", AskDriveWeb do
    pipe_through [:browser, :require_admin_session]

    live_session :app_admin,
      on_mount: [{AskDriveWeb.UserAuth, :require_admin_session}, {AskDriveWeb.AppScope, :app}] do
      live "/:app/admin", AdminLive, :app
    end
  end

  scope "/", AskDriveWeb do
    pipe_through :browser

    live_session :app_chat,
      on_mount: [{AskDriveWeb.UserAuth, :mount_current_user}, {AskDriveWeb.AppScope, :app}] do
      live "/:app", ChatLive
    end
  end
end
