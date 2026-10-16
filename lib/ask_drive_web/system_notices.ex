defmodule AskDriveWeb.SystemNotices do
  @moduledoc """
  Server-wide notices for every LiveView page (mounted in every live_session): when the server
  is about to restart into an update, each open page is told to show "updating" until it can
  reconnect, and then reloads on the new version (spec F-1505; `assets/js/app.js`).
  """
  use Gettext, backend: AskDriveWeb.Gettext

  import Phoenix.LiveView

  def on_mount(:default, _params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(AskDrive.PubSub, "system")
    {:cont, attach_hook(socket, :system_notices, :handle_info, &handle_info/2)}
  end

  defp handle_info({:system_updating, info}, socket) do
    payload = %{
      title: gettext("Updating AskDrive…"),
      message:
        if(info[:to],
          do:
            gettext(
              "Restarting on version %{version}. This page reconnects by itself in about 30 seconds.",
              version: "v#{info.to}"
            ),
          else:
            gettext(
              "Restarting on the new version. This page reconnects by itself in about 30 seconds."
            )
        )
    }

    {:halt, push_event(socket, "askdrive:updating", payload)}
  end

  defp handle_info(_msg, socket), do: {:cont, socket}
end
