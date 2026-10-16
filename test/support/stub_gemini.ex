defmodule AskDrive.StubGemini do
  @moduledoc """
  Stand-in for the Gemini API's generateContent / streamGenerateContent (SSE) / countTokens
  (also Agent Platform's, which takes the same requests), for testing the adapters without a
  key. Behaviour is set per test with `set/2`:

    * `:parts` — the parts returned (may include `%{"thought" => true, ...}`)
    * `:reject_thinking` — answer 400 when thinkingBudget is 0 or thinkingLevel is "minimal"
      (models that must think); `:all` rejects thinkingLevel "low" too (Pro-like)
    * `:no_text` — answer with a candidate without parts and this finishReason (the output
      limit spent on thinking: "MAX_TOKENS")
    * `:rate_limit_once` — answer the first request with 429 + RetryInfo "0.2s"
    * `:models` — what `GET /models` lists (the model list, F-834)
    * `:models_blocked` — answer `GET /models` with the 403 of a key whose API restrictions
      leave out ListModels

  Every request body is sent to the owner as `{:stub_gemini, path, body}`.
  """
  use Plug.Router

  plug :match
  plug Plug.Parsers, parsers: [:json], json_decoder: Jason
  plug :dispatch

  get "/models" do
    send(fetch(:owner), {:stub_gemini, "models", conn.query_params})

    {status, body} =
      if fetch(:models_blocked),
        do:
          {403,
           %{
             error: %{
               code: 403,
               message:
                 "Requests to this API generativelanguage.googleapis.com method google.ai.generativelanguage.v1beta.ModelService.ListModels are blocked.",
               status: "PERMISSION_DENIED",
               details: [%{reason: "API_KEY_SERVICE_BLOCKED"}]
             }
           }},
        else: {200, %{models: fetch(:models) || []}}

    conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(body))
  end

  post "/models/:call" do
    send(fetch(:owner), {:stub_gemini, call, conn.body_params})
    thinking = get_in(conn.body_params, ["generationConfig", "thinkingConfig"]) || %{}

    rejected_levels =
      if fetch(:reject_thinking) == :all, do: ["minimal", "low"], else: ["minimal"]

    rejected? =
      fetch(:reject_thinking) &&
        (thinking["thinkingBudget"] == 0 or thinking["thinkingLevel"] in rejected_levels)

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

      rejected? ->
        error = %{error: %{code: 400, message: "Thinking can't be disabled for this model."}}
        conn |> put_resp_content_type("application/json") |> send_resp(400, Jason.encode!(error))

      fetch(:no_text) && String.ends_with?(call, ":generateContent") ->
        candidate = %{content: %{role: "model"}, finishReason: fetch(:no_text)}

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(%{candidates: [candidate], usageMetadata: %{}}))

      String.ends_with?(call, ":countTokens") ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(%{totalTokens: 1}))

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
    for key <- [
          :parts,
          :reject_thinking,
          :no_text,
          :rate_limit_once,
          :limited,
          :models,
          :models_blocked
        ],
        do: set(key, nil)

    set(:owner, owner)
    {:ok, pid} = Bandit.start_link(plug: __MODULE__, port: 0, ip: {127, 0, 0, 1})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    {pid, "http://127.0.0.1:#{port}"}
  end
end
