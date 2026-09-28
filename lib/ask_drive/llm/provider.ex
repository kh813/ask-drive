defmodule AskDrive.LLM.Provider do
  @moduledoc """
  Behaviour implemented by every LLM backend (spec 6.8).

  Callers never talk to an adapter directly; they go through `AskDrive.LLM`, which resolves
  the configured provider and injects credentials into `opts`.

  Recognised `opts` keys:

    * `:base_url` / `:api_key` — resolved from `settings` (or env) by `AskDrive.LLM`
    * `:timeout` — receive timeout in milliseconds
    * `:system` — system prompt (generation only)
    * `:num_ctx` — context length, honoured by Ollama only
    * `:max_tokens` / `:temperature` — generation limits
    * `:expected_dim` — embedding dimension the caller requires
  """

  @type opts :: keyword()
  @type error ::
          {:unauthorized, String.t()}
          | {:rate_limited, String.t()}
          | {:model_not_found, String.t()}
          | {:server_error, String.t()}
          | {:timeout, String.t()}
          | {:network, term()}
          | {:invalid_response, String.t()}
          | {:unsupported, String.t()}

  @callback generate(model :: String.t(), prompt :: String.t(), opts) ::
              {:ok, String.t()} | {:error, error()}

  @callback embed(model :: String.t(), inputs :: [String.t()], opts) ::
              {:ok, [[float()]]} | {:error, error()}

  @callback list_models(opts) :: {:ok, [String.t()]} | {:error, error()}

  @callback health(opts) :: {:ok, String.t()} | {:error, error()}

  @doc "Whether inference runs on this machine. Drives phase-based residency control (R-106/R-107)."
  @callback local?() :: boolean()

  @doc "Whether the provider exposes an embedding endpoint. Claude does not."
  @callback supports_embedding?() :: boolean()
end
