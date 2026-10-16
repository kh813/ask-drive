# Some tests exercise a real embedding call end-to-end (e.g. asserting a chunk actually gets
# a vector). Whether that is possible depends on whichever provider is configured — Ollama
# running locally, LM Studio, or a cloud API with a real key in the environment — not
# specifically on Ollama, since a run may be set up against any of them. Tests tagged
# `:requires_live_llm` are skipped when the configured embedding backend is unreachable,
# rather than failing the whole suite for an environment that simply has no LLM available.
embedding_reachable? =
  case AskDrive.LLM.health(:embedding) do
    {:ok, _} -> true
    {:error, _} -> false
  end

exclude = if embedding_reachable?, do: [], else: [:requires_live_llm]

unless embedding_reachable? do
  IO.puts(
    "[test_helper] Embedding backend unreachable — skipping tests tagged :requires_live_llm"
  )
end

# Against a real LDAPS directory (OpenLDAP demanding a client certificate, set up by the
# Linux CI): run with LDAP_IT_HOST etc. and `mix test --only ldap_integration`.
exclude = [:ldap_integration | exclude]

ExUnit.start(exclude: exclude)
Ecto.Adapters.SQL.Sandbox.mode(AskDrive.Repo, :manual)
