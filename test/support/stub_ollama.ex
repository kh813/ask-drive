defmodule AskDrive.StubOllama do
  @moduledoc """
  A minimal stand-in for Ollama's /api/embed and streaming /api/generate, for tests that
  need a model without a live one. Each input gets a vector whose first element is the input's length; every request's
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

  # Streams NDJSON like Ollama: the pieces set with put_generate_pieces/1, then done.
  post "/api/generate" do
    if pid = :persistent_term.get({__MODULE__, :owner}, nil),
      do: send(pid, {:stub_generate, conn.body_params})

    pieces = next_pieces()

    cond do
      :persistent_term.get({__MODULE__, :reject_think}, false) and
          Map.has_key?(conn.body_params, "think") ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, Jason.encode!(%{error: "\"stub\" does not support thinking"}))

      conn.body_params["stream"] == false ->
        text = pieces |> Enum.reject(&match?({:thinking, _}, &1)) |> Enum.join()

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(%{response: text, done: true}))

      true ->
        stream_pieces(conn, pieces)
    end
  end

  defp stream_pieces(conn, pieces) do
    conn = conn |> put_resp_content_type("application/x-ndjson") |> send_chunked(200)

    conn =
      Enum.reduce(pieces, conn, fn piece, conn ->
        line =
          case piece do
            {:thinking, text} -> %{thinking: text, response: "", done: false}
            text -> %{response: text, done: false}
          end

        {:ok, conn} = chunk(conn, Jason.encode!(line) <> "\n")
        conn
      end)

    {:ok, conn} = chunk(conn, Jason.encode!(%{response: "", done: true}) <> "\n")
    conn
  end

  get "/api/tags" do
    names = :persistent_term.get({__MODULE__, :installed}, [])

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{models: Enum.map(names, &%{name: &1})}))
  end

  # Streams two progress lines then success, and marks the model installed.
  post "/api/pull" do
    model = conn.body_params["model"]
    if pid = :persistent_term.get({__MODULE__, :owner}, nil), do: send(pid, {:stub_pull, model})
    conn = conn |> put_resp_content_type("application/x-ndjson") |> send_chunked(200)

    lines = [
      %{status: "pulling manifest"},
      %{status: "downloading", total: 100, completed: 50},
      %{status: "success"}
    ]

    conn =
      Enum.reduce(lines, conn, fn line, conn ->
        {:ok, conn} = chunk(conn, Jason.encode!(line) <> "\n")
        conn
      end)

    put_installed([model | :persistent_term.get({__MODULE__, :installed}, [])])
    conn
  end

  match _ do
    send_resp(conn, 404, "")
  end

  @doc """
  Sets what /api/generate streams back: a list of pieces (every call), or
  `{:sequence, [pieces1, pieces2, …]}` for successive calls. A piece is a response string or
  `{:thinking, text}` (sent in Ollama's separate thinking field).
  """
  def put_generate_pieces(pieces), do: :persistent_term.put({__MODULE__, :pieces}, pieces)

  defp next_pieces do
    case :persistent_term.get({__MODULE__, :pieces}, ["要約です。"]) do
      {:sequence, [current | rest]} ->
        :persistent_term.put(
          {__MODULE__, :pieces},
          {:sequence, if(rest == [], do: [current], else: rest)}
        )

        current

      pieces ->
        pieces
    end
  end

  @doc "Makes /api/generate reject requests carrying `think` (models without thinking)."
  def reject_think(on?), do: :persistent_term.put({__MODULE__, :reject_think}, on?)

  @doc "Sets the model names /api/tags reports as installed."
  def put_installed(names), do: :persistent_term.put({__MODULE__, :installed}, names)

  @doc "Starts the stub on a free port and returns its base URL."
  def start!(owner, dim \\ 1024) do
    :persistent_term.put({__MODULE__, :owner}, owner)
    :persistent_term.put({__MODULE__, :dim}, dim)
    :persistent_term.put({__MODULE__, :installed}, [])
    :persistent_term.put({__MODULE__, :reject_think}, false)
    {:ok, pid} = Bandit.start_link(plug: __MODULE__, port: 0, ip: {127, 0, 0, 1})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    {pid, "http://127.0.0.1:#{port}"}
  end
end
