defmodule AskDrive.StubOllama do
  @moduledoc """
  A minimal stand-in for Ollama's /api/embed, for tests that need embeddings without a live
  model. Each input gets a vector whose first element is the input's length; every request's
  batch size is sent to the owning test process as `{:stub_embed, n}`.
  """
  use Plug.Router

  plug :match
  plug Plug.Parsers, parsers: [:json], json_decoder: Jason
  plug :dispatch

  post "/api/embed" do
    inputs = conn.body_params["input"] || []

    if pid = :persistent_term.get({__MODULE__, :owner}, nil),
      do: send(pid, {:stub_embed, length(inputs)})

    dim = :persistent_term.get({__MODULE__, :dim}, 1024)

    embeddings =
      Enum.map(inputs, fn t -> [String.length(t) * 1.0 | List.duplicate(0.0, dim - 1)] end)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{embeddings: embeddings}))
  end

  match _ do
    send_resp(conn, 404, "")
  end

  @doc "Starts the stub on a free port and returns its base URL."
  def start!(owner, dim \\ 1024) do
    :persistent_term.put({__MODULE__, :owner}, owner)
    :persistent_term.put({__MODULE__, :dim}, dim)
    {:ok, pid} = Bandit.start_link(plug: __MODULE__, port: 0, ip: {127, 0, 0, 1})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    {pid, "http://127.0.0.1:#{port}"}
  end
end
