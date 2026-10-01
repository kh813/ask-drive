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
    plug AskDriveWeb.Plugs.SetLocale
    plug :fetch_current_user
    # only devices with a certificate issued here, when restricted (spec 6.14) — before the
    # login page and everything else
    plug AskDriveWeb.Plugs.ClientCertGate
    # until the first-access setup is done, every page leads to /setup (spec 6.12)
    plug AskDriveWeb.Plugs.RequireSetup
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # --- Locale switcher ------------------------------------------------------
  scope "/", AskDriveWeb do
    pipe_through :browser

    get "/locale/:locale", LocaleController, :set_locale
  end

  # --- Public: sign-in only (spec 6.9) --------------------------------------
  scope "/", AskDriveWeb do
    pipe_through :browser

    get "/login", AuthController, :login
    post "/login/ldap", AuthController, :ldap_login
    get "/auth/google", AuthController, :request
    get "/auth/google/callback", AuthController, :callback
    get "/logout", AuthController, :logout
    delete "/logout", AuthController, :logout
  end

  # --- Portal: the list of apps (spec 6.11) --------------------------------
  # Login required when it is switched on (spec F-1308); while it is off (the POC), the
  # guest stands in and everyone gets in. The first-access setup is always reachable.
  scope "/", AskDriveWeb do
    pipe_through :browser

    live_session :setup,
      on_mount: [
        {AskDriveWeb.Plugs.SetLocale, :default},
        {AskDriveWeb.UserAuth, :mount_current_user}
      ] do
      live "/setup", SetupLive
    end

    live_session :portal,
      on_mount: [
        {AskDriveWeb.Plugs.SetLocale, :default},
        {AskDriveWeb.UserAuth, :require_login_when_enabled}
      ] do
      live "/", PortalLive
    end
  end

  # --- Elevation prompt: signed in and allowed to try, but not yet elevated --
  scope "/", AskDriveWeb do
    pipe_through [:browser, :require_authenticated_user]

    get "/admin/elevate", AdminAccessController, :new
    post "/admin/elevate", AdminAccessController, :create
    get "/admin/reauth", AdminAccessController, :reauth
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

    # an issued client certificate, downloaded once (spec 6.14)
    get "/admin/client-certs/:token", ClientCertController, :download

    # Platform administration: apps, users, SSL, Ollama, the nightly window (spec 6.11)
    live_session :admin,
      on_mount: [
        {AskDriveWeb.Plugs.SetLocale, :default},
        {AskDriveWeb.UserAuth, :require_admin_session}
      ] do
      live "/admin", AdminLive, :platform
    end
  end

  # --- A desk's Drive sync account (spec F-345) -----------------------------
  # Authorizing / revoking it is part of a desk's settings, so it's for that desk's
  # administrators inside its admin screen (checked per desk in AuthController), not only
  # for platform administrators.
  scope "/", AskDriveWeb do
    pipe_through [:browser, :require_authenticated_user]

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

  # --- An app's admin screen: its own password, its assigned administrators (F-1113) ---
  scope "/", AskDriveWeb do
    pipe_through [:browser, :require_authenticated_user]

    get "/:app/admin/elevate", AppAdminAccessController, :new
    post "/:app/admin/elevate", AppAdminAccessController, :create
    get "/:app/admin/reauth", AppAdminAccessController, :reauth
    get "/:app/admin/release", AppAdminAccessController, :release
  end

  # --- Apps (spec 6.11) — last, so the "/:app" catch-all can't shadow any route above ---
  # Reserved slugs (AskDrive.Apps.App.reserved_slugs/0) keep apps from claiming those paths.
  scope "/", AskDriveWeb do
    pipe_through [:browser, :require_app_admin_session]

    live_session :app_admin,
      on_mount: [
        {AskDriveWeb.Plugs.SetLocale, :default},
        {AskDriveWeb.UserAuth, :require_app_admin_session},
        {AskDriveWeb.AppScope, :app}
      ] do
      live "/:app/admin", AdminLive, :app
    end
  end

  scope "/", AskDriveWeb do
    pipe_through :browser

    # the per-app passphrase (spec F-1112): a plain POST so the unlock goes into the session
    post "/:app/unlock", AppAccessController, :unlock

    live_session :app_chat,
      on_mount: [
        {AskDriveWeb.Plugs.SetLocale, :default},
        {AskDriveWeb.UserAuth, :require_login_when_enabled},
        {AskDriveWeb.AppScope, :app}
      ] do
      live "/:app", ChatLive
    end
  end
end
