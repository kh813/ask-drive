defmodule AskDrive.StubValueDomain do
  @moduledoc """
  Stand-in for the Value-Domain DNS API (`GET` / `PUT /domains/:zone/dns`): the zone is one
  text of records, replaced whole by a PUT, as the real API does. Options with `set/2`:

    * `:records` — the zone text (set before a test; read after it)
    * `:status` — answer every request with this HTTP status instead
    * `:drop_first_line_on_put` — lose the first record on PUT (an API that mangles the zone)

  Every request is reported to the owner as `{:stub_vd, method, zone, body, authorization}`.
  """
  use Plug.Router

  plug :match
  plug Plug.Parsers, parsers: [:json], json_decoder: Jason
  plug :dispatch

  get "/domains/:zone/dns" do
    report(conn, zone)

    case fetch(:status) do
      nil ->
        json(conn, 200, %{
          "results" => %{"records" => fetch(:records), "ns_type" => "valuedomain1", "ttl" => 3600}
        })

      status ->
        json(conn, status, %{"errors" => %{"message" => "error"}})
    end
  end

  put "/domains/:zone/dns" do
    report(conn, zone)

    case fetch(:status) do
      nil ->
        records = conn.body_params["records"]

        records =
          if fetch(:drop_first_line_on_put),
            do: records |> String.split("\n") |> tl() |> Enum.join("\n"),
            else: records

        set(:records, records)
        json(conn, 200, %{"results" => %{"status" => "success"}})

      status ->
        json(conn, status, %{"errors" => %{"message" => "error"}})
    end
  end

  defp report(conn, zone) do
    auth = conn |> Plug.Conn.get_req_header("authorization") |> List.first()
    send(fetch(:owner), {:stub_vd, conn.method, zone, conn.body_params, auth})
  end

  defp json(conn, status, body),
    do:
      conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(body))

  def set(key, value), do: :persistent_term.put({__MODULE__, key}, value)
  def fetch(key), do: :persistent_term.get({__MODULE__, key}, nil)

  def start!(owner) do
    for key <- [:records, :status, :drop_first_line_on_put], do: set(key, nil)
    set(:owner, owner)
    {:ok, pid} = Bandit.start_link(plug: __MODULE__, port: 0, ip: {127, 0, 0, 1})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    {pid, "http://127.0.0.1:#{port}"}
  end
end
