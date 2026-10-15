defmodule AskDrive.LLM.VertexTest do
  @moduledoc """
  Google Agent Platform (formerly Vertex AI) with an API key (spec F-835): the Gemini API's
  requests, sent to Agent Platform's endpoint.
  """
  use ExUnit.Case, async: false

  alias AskDrive.LLM
  alias AskDrive.LLM.Providers.Vertex
  alias AskDrive.Settings.Setting
  alias AskDrive.StubGemini

  test "the endpoint: global without a project, else the project's location" do
    global = "https://aiplatform.googleapis.com/v1/publishers/google"
    assert Vertex.base_url(nil, nil) == global
    assert Vertex.base_url("", "asia-northeast1") == global

    assert Vertex.base_url("my-proj", nil) ==
             "https://aiplatform.googleapis.com/v1/projects/my-proj/locations/global/publishers/google"

    assert Vertex.base_url("my-proj", "asia-northeast1") ==
             "https://asia-northeast1-aiplatform.googleapis.com/v1/projects/my-proj/locations/asia-northeast1/publishers/google"
  end

  test "the settings give the provider its endpoint and key" do
    setting = %Setting{
      vertex_api_key: "vk",
      vertex_project: "my-proj",
      vertex_location: "us-central1"
    }

    assert LLM.provider_opts("vertex", setting) == [
             base_url:
               "https://us-central1-aiplatform.googleapis.com/v1/projects/my-proj/locations/us-central1/publishers/google",
             api_key: "vk"
           ]

    assert LLM.requires_api_key?("vertex")
    refute LLM.local?("vertex")
    refute "vertex" in LLM.embedding_providers()
    assert "vertex" in Setting.cloud_providers()
  end

  describe "against the endpoint" do
    setup do
      {server, url} = StubGemini.start!(self())
      on_exit(fn -> Process.exit(server, :normal) end)
      %{opts: [base_url: url, api_key: "vk"]}
    end

    test "generates and streams as the Gemini API does", %{opts: opts} do
      StubGemini.set(:parts, [%{"text" => "考え中", "thought" => true}, %{"text" => "回答です"}])

      assert {:ok, "回答です"} = Vertex.generate("gemini-2.5-flash", "q", opts ++ [think: false])
      assert_received {:stub_gemini, "gemini-2.5-flash:generateContent", body}
      assert body["generationConfig"]["thinkingConfig"] == %{"thinkingBudget" => 0}

      me = self()
      on_delta = fn piece -> send(me, {:delta, piece}) end

      assert {:ok, "回答です"} =
               Vertex.generate_stream("gemini-2.5-flash", "q", opts, on_delta)

      assert_received {:stub_gemini, "gemini-2.5-flash:streamGenerateContent", _}
      assert_received {:delta, "回答です"}
    end

    test "the health check counts tokens with the model in use", %{opts: opts} do
      assert {:ok, _} = Vertex.health(opts ++ [model: "gemini-2.5-flash"])
      assert_received {:stub_gemini, "gemini-2.5-flash:countTokens", _}
    end

    test "embeddings and the model list are another provider's", %{opts: opts} do
      assert {:error, {:unsupported, _}} = Vertex.embed("m", ["x"], opts)
      assert {:error, {:unsupported, _}} = Vertex.list_models(opts)
    end
  end

  test "project ID and location are checked" do
    cs =
      Setting.changeset(%Setting{}, %{vertex_project: "My Project", vertex_location: "tokyo 1"})

    assert cs.errors[:vertex_project]
    assert cs.errors[:vertex_location]

    cs =
      Setting.changeset(%Setting{}, %{
        vertex_project: "my-proj-1",
        vertex_location: "asia-northeast1"
      })

    refute cs.errors[:vertex_project]
    refute cs.errors[:vertex_location]
  end
end
