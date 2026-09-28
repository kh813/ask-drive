defmodule AskDrive.StubGemini do
  @moduledoc """
  Stand-in for the Gemini API's generateContent / streamGenerateContent (SSE), for testing
  the adapter without a key. Behaviour is set per test with `set/2`:

    * `:parts` — the parts returned (may include `%{"thought" => true, ...}`)
    * `:reject_thinking` — answer 400 when thinkingBudget is 0 (models that must think)
    * `:rate_limit_once` — answer the first request with 429 + RetryInfo "0.2s"

  Every request body is sent to the owner as `{:stub_gemini, path, body}`.
  """
  use Plug.Router

  plug :match
  plug Plug.Parsers, parsers: [:json], json_decoder: Jason
  plug :dispatch

  post "/models/:call" do
    send(fetch(:owner), {:stub_gemini, call, conn.body_params})
    budget = get_in(conn.body_params, ["generationConfig", "thinkingConfig", "thinkingBudget"])

    cond do
      fetch(:rate_limit_once) && !fetch(:limited) ->
        set(:limited, true)

        error = %{
          error: %{
            code: 429,
            message: "Resource exhausted",
            details: [
              %{"@type" => "type.googleapis.com/google.rpc.RetryInfo", "retryDelay" => "0.2s"}
            ]
          }
        }

        conn |> put_resp_content_type("application/json") |> send_resp(429, Jason.encode!(error))

      fetch(:reject_thinking) && budget == 0 ->
        error = %{error: %{code: 400, message: "Thinking can't be disabled for this model."}}
        conn |> put_resp_content_type("application/json") |> send_resp(400, Jason.encode!(error))

      String.ends_with?(call, ":streamGenerateContent") ->
        conn = conn |> put_resp_content_type("text/event-stream") |> send_chunked(200)

        Enum.reduce(fetch(:parts) || [], conn, fn part, conn ->
          event = %{candidates: [%{content: %{parts: [part]}}]}
          {:ok, conn} = chunk(conn, "data: " <> Jason.encode!(event) <> "\r\n\r\n")
          conn
        end)

      true ->
        body = %{candidates: [%{content: %{parts: fetch(:parts) || []}}]}
        conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(body))
    end
  end

  def set(key, value), do: :persistent_term.put({__MODULE__, key}, value)
  defp fetch(key), do: :persistent_term.get({__MODULE__, key}, nil)

  def start!(owner) do
    for key <- [:parts, :reject_thinking, :rate_limit_once, :limited], do: set(key, nil)
    set(:owner, owner)
    {:ok, pid} = Bandit.start_link(plug: __MODULE__, port: 0, ip: {127, 0, 0, 1})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    {pid, "http://127.0.0.1:#{port}"}
  end
end
