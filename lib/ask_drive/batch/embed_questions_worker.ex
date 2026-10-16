defmodule AskDrive.Batch.EmbedQuestionsWorker do
  @moduledoc """
  Oban worker for embedding generated hypothetical questions into `vec_qa_pairs` for Tier 1 search.
  """
  use Oban.Worker,
    queue: :embed,
    max_attempts: 3

  import Ecto.Query, warn: false
  require Logger
  alias AskDrive.QA.QAPair
  alias AskDrive.{Repo, Settings, Vector}
  alias AskDrive.LLM
  alias AskDrive.LLM.Semaphore

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"qa_pair_id" => qa_pair_id}}) do
    case Repo.get(QAPair, qa_pair_id) do
      nil ->
        {:ok, :not_found}

      %QAPair{} = qa ->
        embed_qa_question(qa)
    end
  end

  def perform(%Oban.Job{args: %{"qa_pair_ids" => ids}}) when is_list(ids) do
    qas = Repo.all(from q in QAPair, where: q.id in ^ids)
    setting = Settings.get_setting!()

    questions = Enum.map(qas, & &1.question)

    embed_result =
      Semaphore.run(fn ->
        LLM.embed(setting.embed_model, questions, setting: setting)
      end)

    case embed_result do
      {:ok, embeddings} ->
        Repo.transaction(fn ->
          Enum.zip(qas, embeddings)
          |> Enum.each(fn {qa, emb_floats} ->
            blob = Vector.encode(emb_floats)
            json_vec = Vector.to_json(emb_floats)

            qa
            |> QAPair.changeset(%{question_embedding: blob})
            |> Repo.update!()

            Repo.query!("DELETE FROM vec_qa_pairs WHERE qa_pair_id = ?", [qa.id])

            Repo.query!(
              "INSERT INTO vec_qa_pairs(qa_pair_id, question_embedding) VALUES (?, ?)",
              [qa.id, json_vec]
            )
          end)
        end)

        {:ok, length(qas)}

      {:error, reason} ->
        Logger.error("EmbedQuestionsWorker batch failure: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp embed_qa_question(%QAPair{} = qa) do
    setting = Settings.get_setting!()

    embed_result =
      Semaphore.run(fn ->
        LLM.embed(setting.embed_model, [qa.question], setting: setting)
      end)

    case embed_result do
      {:ok, [emb_floats | _]} ->
        blob = Vector.encode(emb_floats)
        json_vec = Vector.to_json(emb_floats)

        Repo.transaction(fn ->
          {:ok, _} =
            qa
            |> QAPair.changeset(%{question_embedding: blob})
            |> Repo.update()

          Repo.query!("DELETE FROM vec_qa_pairs WHERE qa_pair_id = ?", [qa.id])

          Repo.query!(
            "INSERT INTO vec_qa_pairs(qa_pair_id, question_embedding) VALUES (?, ?)",
            [qa.id, json_vec]
          )
        end)

        {:ok, :embedded}

      {:error, reason} ->
        Logger.error("EmbedQuestionsWorker failed for qa #{qa.id}: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
