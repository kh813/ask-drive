defmodule AskDrive.LLM.HTTP do
  @moduledoc """
  Shared HTTP plumbing for the LLM provider adapters: retries with exponential backoff and
  the error classification of spec 8.6.

  Req's own retry is switched off (`retry: false`) so there is exactly one retry policy
  rather than two nested ones — Req would otherwise back off four times *inside* each of the
  attempts below.

  Only rate limits, server errors and timeouts are retried. A refused connection or a failed
  DNS lookup will not resolve itself a second later, and sleeping through three attempts
  turns "Ollama is not running" into a multi-second stall on every request.

  Request and response bodies are never logged — they carry document text and API keys
  (spec 9.6 N-606).
  """
  require Logger

  @max_attempts 3
  # Rate limits (429) get more attempts and honour the provider's own wait hint: Gemini's
  # free tier answers "retry in 30s", which three quick retries 1-2 s apart never survive,
  # so a nightly batch on the cloud lost chunk after chunk.
  @rate_limit_attempts 5
  @max_hint_ms 60_000
  @base_backoff_ms 1_000

  @doc """
  POSTs a JSON payload.

  Pass `retry: false` for interactive diagnostics, where a fast answer beats a thorough one.
  """
  def post_json(url, payload, headers, timeout, opts \\ []) do
    req_opts = [json: payload, headers: headers, receive_timeout: timeout, retry: false]
    request(:post, url, req_opts, 1, opts)
  end

  @doc """
  GETs a JSON document. Accepts the same `retry: false` option as `post_json/5`.
  """
  def get_json(url, headers, timeout, opts \\ []) do
    request(:get, url, [headers: headers, receive_timeout: timeout, retry: false], 1, opts)
  end

  defp request(method, url, req_opts, attempt, opts) do
    case apply(Req, method, [url, req_opts]) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %{status: 429, body: body} = resp} ->
        retry_or_fail(method, url, req_opts, attempt, opts, classify(429, body),
          hint_ms: retry_hint_ms(resp),
          max_attempts: @rate_limit_attempts
        )

      {:ok, %{status: status, body: body}} when status in [500, 502, 503, 504] ->
        retry_or_fail(method, url, req_opts, attempt, opts, classify(status, body))

      {:ok, %{status: status, body: body}} ->
        {:error, classify(status, body)}

      {:error, %{__struct__: Req.TransportError, reason: :timeout}} ->
        retry_or_fail(method, url, req_opts, attempt, opts, {:timeout, "receive timeout"})

      {:error, reason} ->
        {:error, {:network, reason}}
    end
  end

  defp retry_or_fail(method, url, req_opts, attempt, opts, error, policy \\ []) do
    max_attempts = Keyword.get(policy, :max_attempts, @max_attempts)

    if attempt >= max_attempts or Keyword.get(opts, :retry, true) == false do
      Logger.warning(
        "LLM request to #{host_of(url)} failed after #{attempt} attempt(s): #{kind(error)} (#{detail(error)})"
      )

      {:error, error}
    else
      delay =
        case Keyword.get(policy, :hint_ms) do
          ms when is_integer(ms) and ms > 0 -> min(ms, @max_hint_ms) + :rand.uniform(250)
          _ -> @base_backoff_ms * 2 ** (attempt - 1) + :rand.uniform(250)
        end

      Logger.info("LLM request to #{host_of(url)} #{kind(error)}; retrying in #{delay}ms")
      Process.sleep(trunc(delay))
      request(method, url, req_opts, attempt + 1, opts)
    end
  end

  @doc """
  The wait a provider asks for on a 429, in milliseconds: the `Retry-After` header
  (OpenAI, Anthropic) or Gemini's `google.rpc.RetryInfo.retryDelay` ("30s", "1.5s").
  """
  def retry_hint_ms(%{headers: headers, body: body}) do
    header =
      case Map.get(headers || %{}, "retry-after") do
        [value | _] -> parse_seconds(value)
        value when is_binary(value) -> parse_seconds(value)
        _ -> nil
      end

    header || gemini_retry_delay(body)
  end

  def retry_hint_ms(_), do: nil

  defp gemini_retry_delay(%{"error" => %{"details" => details}}) when is_list(details) do
    Enum.find_value(details, fn
      %{"retryDelay" => delay} -> parse_seconds(delay)
      _ -> nil
    end)
  end

  defp gemini_retry_delay(_), do: nil

  defp parse_seconds(value) when is_binary(value) do
    case Float.parse(String.trim_trailing(String.trim(value), "s")) do
      {seconds, _} -> round(seconds * 1000)
      :error -> nil
    end
  end

  defp parse_seconds(_), do: nil

  @doc """
  Maps an HTTP status onto the error taxonomy of spec 8.6.
  """
  def classify(status, body) do
    message = error_message(body) || "HTTP #{status}"

    case status do
      s when s in [401, 403] -> {:unauthorized, message}
      404 -> {:model_not_found, message}
      429 -> {:rate_limited, message}
      s when s >= 500 -> {:server_error, message}
      _ -> {:invalid_response, message}
    end
  end

  @doc """
  Renders an error tuple as a short, user-facing Japanese hint for the admin dashboard.
  """
  def describe({:unauthorized, msg}), do: "認証に失敗しました。API キーを確認してください (#{msg})"
  def describe({:rate_limited, msg}), do: "レート制限に達しました (#{msg})"
  def describe({:model_not_found, msg}), do: "モデルが見つかりません。モデル名を確認してください (#{msg})"
  def describe({:server_error, msg}), do: "プロバイダ側のエラーです (#{msg})"
  def describe({:timeout, msg}), do: "タイムアウトしました (#{msg})"
  def describe({:network, _reason}), do: "接続できませんでした。エンドポイントの疎通を確認してください"
  def describe({:invalid_response, msg}), do: "想定外の応答です (#{msg})"
  def describe({:unsupported, msg}), do: msg
  def describe(other), do: inspect(other)

  defp kind({k, _}), do: to_string(k)
  defp kind(other), do: inspect(other)

  defp detail({_, msg}) when is_binary(msg), do: msg
  defp detail({_, other}), do: inspect(other)
  defp detail(other), do: inspect(other)

  defp error_message(%{"error" => %{"message" => message}}) when is_binary(message), do: message
  defp error_message(%{"error" => message}) when is_binary(message), do: message
  defp error_message(%{"message" => message}) when is_binary(message), do: message
  defp error_message(_), do: nil

  defp host_of(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) -> host
      _ -> "unknown host"
    end
  end
end
