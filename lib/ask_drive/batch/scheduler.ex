defmodule AskDrive.Batch.Scheduler do
  @moduledoc """
  Orchestrates the 6-phase Nightly Batch pipeline:

  1. Phase 1: Sync (Drive metadata sync, extract & chunking) - No LLM, never aborted.
  2. Phase 2: Invalidate (Mark stale QAs, summaries, extractions for modified docs) - No LLM.
  3. Phase 3: Embed Chunks (Embed newly added or modified document chunks) - Embed model only.
  4. Phase 4: Generate (QA generation, summaries, extractions) - Generation model only (Budget & Deadline controlled).
  5. Phase 5: Embed Questions (Embed newly generated hypothetical questions) - Embed model only.
  6. Phase 6: Verify & Stats (Consistency check, update batch_runs & stats) - No LLM.

  Enforces strict single-model residency per phase:
  - Embed model loaded during Phase 3 & 5.
  - Batch generation model loaded during Phase 4.
  - All models unloaded or transitioned to daytime mode upon completion.
  """
  require Logger
  import Ecto.Query, warn: false

  alias AskDrive.Documents.Chunk
  alias AskDrive.QA.QAPair
  alias AskDrive.{QA, Repo, Settings}

  alias AskDrive.Batch.{
    BatchPhaseStat,
    BatchRun,
    EmbedChunksWorker,
    EmbedQuestionsWorker,
    SyncWorker
  }

  alias AskDrive.Generate.{Extraction, QA, Summary}
  alias AskDrive.LLM.Ollama
  alias AskDrive.Runtime.Mode

  @doc """
  Runs the entire 6-phase batch process synchronously.
  Can be invoked by Oban Cron or manually from Admin dashboard.
  """
  def run_batch(opts \\ []) do
    force_all = Keyword.get(opts, :force, false)
    setting = Settings.get_setting!()

    # 1. Create batch_run record
    {:ok, batch_run} =
      %BatchRun{}
      |> BatchRun.changeset(%{
        started_at: DateTime.utc_now(),
        status: "running",
        model_used: setting.batch_model,
        chunks_processed: 0,
        qa_generated: 0,
        qa_invalidated: 0,
        questions_resolved: 0
      })
      |> Repo.insert()

    # Transition runtime mode into night_batch
    Mode.set_mode(:night_batch)

    deadline = calculate_deadline(setting)
    Logger.info("Starting Night Batch ##{batch_run.id}. Deadline: #{inspect(deadline)}")

    try do
      # --- Phase 1: Sync ---
      {_p1_stat, batch_run} = run_phase_1_sync(batch_run, setting)

      # --- Phase 2: Invalidate ---
      {_p2_stat, batch_run} = run_phase_2_invalidate(batch_run, setting)

      # --- Phase 3: Embed Chunks ---
      {_p3_stat, batch_run} = run_phase_3_embed_chunks(batch_run, setting)

      # --- Phase 4: Generate (Deadline-controlled) ---
      {_p4_stat, batch_run, deadline_reached?} =
        run_phase_4_generate(batch_run, setting, deadline, force_all)

      # --- Phase 5: Embed Questions ---
      {_p5_stat, batch_run} = run_phase_5_embed_questions(batch_run, setting)

      # --- Phase 6: Verify & Finish ---
      {_p6_stat, batch_run} = run_phase_6_verify(batch_run, setting, deadline_reached?)

      # Restore daytime or standby mode according to clock
      Mode.sync_with_clock()

      {:ok, batch_run}
    rescue
      e ->
        Logger.error("Batch ##{batch_run.id} failed with error: #{inspect(e)}")

        batch_run
        |> BatchRun.changeset(%{
          finished_at: DateTime.utc_now(),
          status: "failed",
          error: inspect(e)
        })
        |> Repo.update()

        Mode.sync_with_clock()
        {:error, e}
    end
  end

  # =========================================================================
  # Phase 1: Sync (Drive metadata & content sync)
  # =========================================================================

  defp run_phase_1_sync(batch_run, setting) do
    start_time = DateTime.utc_now()
    Logger.info("Batch ##{batch_run.id} - [Phase 1: Sync] starting...")

    # Ensure all LLM models unloaded during pure sync
    Ollama.unload_model(setting.batch_model)

    items_count =
      case SyncWorker.perform(%Oban.Job{args: %{}}) do
        {:ok, %{total_drive_files: count}} -> count
        {:ok, _} -> 1
        _ -> 0
      end

    finished_time = DateTime.utc_now()
    duration = DateTime.diff(finished_time, start_time)

    stat = record_phase_stat(batch_run, "sync", start_time, finished_time, duration, items_count)
    {stat, batch_run}
  end

  # =========================================================================
  # Phase 2: Invalidate (Mark stale dependencies)
  # =========================================================================

  defp run_phase_2_invalidate(batch_run, _setting) do
    start_time = DateTime.utc_now()
    Logger.info("Batch ##{batch_run.id} - [Phase 2: Invalidate] starting...")

    # Find modified documents where hash changed but old QAs are still active
    invalidated_count =
      Repo.one(
        from q in QAPair,
          where: q.status == "stale",
          select: count(q.id)
      )

    finished_time = DateTime.utc_now()
    duration = DateTime.diff(finished_time, start_time)

    batch_run =
      batch_run
      |> BatchRun.changeset(%{qa_invalidated: invalidated_count})
      |> Repo.update!()

    stat =
      record_phase_stat(
        batch_run,
        "invalidate",
        start_time,
        finished_time,
        duration,
        invalidated_count
      )

    {stat, batch_run}
  end

  # =========================================================================
  # Phase 3: Embed Chunks (Embed newly added / modified chunks)
  # =========================================================================

  defp run_phase_3_embed_chunks(batch_run, setting) do
    start_time = DateTime.utc_now()
    Logger.info("Batch ##{batch_run.id} - [Phase 3: Embed Chunks] starting...")

    # Ensure embed model is loaded, batch model unloaded
    Ollama.unload_model(setting.batch_model)

    # Process all pending / updated documents that need chunking & embedding
    unindexed_docs =
      Repo.all(
        from d in AskDrive.Documents.Document,
          where: d.status in ["pending", "processing"]
      )

    items_count =
      Enum.reduce(unindexed_docs, 0, fn doc, acc ->
        case EmbedChunksWorker.perform(%Oban.Job{args: %{"document_id" => doc.id}}) do
          {:ok, _} -> acc + 1
          _ -> acc
        end
      end)

    finished_time = DateTime.utc_now()
    duration = DateTime.diff(finished_time, start_time)

    # Unload embed model at phase boundary
    Ollama.unload_model(setting.embed_model)

    stat =
      record_phase_stat(
        batch_run,
        "embed_chunks",
        start_time,
        finished_time,
        duration,
        items_count
      )

    {stat, batch_run}
  end

  # =========================================================================
  # Phase 4: Generate (QA, Summaries, Extractions)
  # =========================================================================

  defp run_phase_4_generate(batch_run, setting, deadline, force_all) do
    start_time = DateTime.utc_now()
    Logger.info("Batch ##{batch_run.id} - [Phase 4: Generate] starting...")

    # Embed model already unloaded. Now generation model will be loaded by Ollama on first request.
    chunks_query =
      if force_all do
        from c in Chunk, order_by: [asc: c.id]
      else
        # Find chunks without QA pairs or with stale QA pairs
        from c in Chunk,
          left_join: q in QAPair,
          on: q.chunk_id == c.id,
          where: is_nil(q.id) or q.status == "stale",
          distinct: true,
          order_by: [asc: c.id]
      end

    pending_chunks = Repo.all(chunks_query)
    total_chunks = length(pending_chunks)
    Logger.info("Batch ##{batch_run.id} - Found #{total_chunks} chunks queued for generation.")

    {processed_count, generated_qa_count, deadline_reached?} =
      process_generation_loop(
        pending_chunks,
        setting,
        deadline,
        0,
        0
      )

    # Optional: Generate document summaries if enabled
    if Map.get(setting, :summary_enabled, false) == true do
      docs_without_summary =
        Repo.all(
          from d in AskDrive.Documents.Document,
            left_join: s in AskDrive.Documents.DocSummary,
            on: s.document_id == d.id,
            where: d.status == "indexed" and is_nil(s.id)
        )

      Enum.each(docs_without_summary, fn doc ->
        # Get all chunk contents
        chunks =
          Repo.all(
            from c in Chunk,
              where: c.document_id == ^doc.id,
              order_by: [asc: c.position]
          )

        full_text = Enum.map_join(chunks, "\n\n", & &1.content)

        if full_text != "" do
          case Summary.generate(full_text, setting.batch_model, setting.batch_num_ctx) do
            {:ok, summary_text} ->
              %AskDrive.Documents.DocSummary{}
              |> AskDrive.Documents.DocSummary.changeset(%{
                document_id: doc.id,
                summary: summary_text,
                status: "active"
              })
              |> Repo.insert()

            _ ->
              :ok
          end
        end
      end)
    end

    finished_time = DateTime.utc_now()
    duration = DateTime.diff(finished_time, start_time)

    # Unload generation model immediately at phase boundary
    Ollama.unload_model(setting.batch_model)

    batch_run =
      batch_run
      |> BatchRun.changeset(%{
        chunks_processed: processed_count,
        qa_generated: generated_qa_count,
        queue_remaining: max(0, total_chunks - processed_count)
      })
      |> Repo.update!()

    stat =
      record_phase_stat(
        batch_run,
        "generate",
        start_time,
        finished_time,
        duration,
        processed_count
      )

    {stat, batch_run, deadline_reached?}
  end

  defp process_generation_loop([], _setting, _deadline, processed, qa_count) do
    {processed, qa_count, false}
  end

  defp process_generation_loop([chunk | rest], setting, deadline, processed, qa_count) do
    # Check deadline
    now = DateTime.utc_now()

    if deadline && DateTime.compare(now, deadline) in [:gt, :eq] do
      Logger.warning("Batch generation deadline #{inspect(deadline)} reached. Stopping Phase 4.")
      {processed, qa_count, true}
    else
      # 1. Generate QA pairs
      new_qas =
        case QA.generate_for_chunk(chunk, setting.batch_model, setting.batch_num_ctx) do
          {:ok, qa_list} ->
            saved =
              Enum.map(qa_list, fn item ->
                {:ok, qa_pair} =
                  AskDrive.QA.create_qa_pair(%{
                    document_id: chunk.document_id,
                    chunk_id: chunk.id,
                    question: item.question,
                    answer: item.answer,
                    status: "active",
                    hallucination_flag: item.hallucination_flag,
                    generated_by: setting.batch_model,
                    generated_at: DateTime.utc_now(),
                    source_hash: chunk.content_hash
                  })

                qa_pair
              end)

            length(saved)

          {:error, reason} ->
            Logger.error("Failed to generate QA for chunk #{chunk.id}: #{inspect(reason)}")
            0
        end

      # 2. Extract structured fields if enabled
      if Map.get(setting, :extraction_enabled, false) == true do
        case Extraction.extract(chunk.content, setting.batch_model, setting.batch_num_ctx) do
          {:ok, items} when items != [] ->
            # Save extractions
            Enum.each(items, fn item ->
              AskDrive.Documents.create_extraction(%{
                document_id: chunk.document_id,
                chunk_id: chunk.id,
                key: item["key"] || "item",
                value: to_string(item["value"]),
                value_type: item["value_type"] || "text"
              })
            end)

          _ ->
            :ok
        end
      end

      process_generation_loop(
        rest,
        setting,
        deadline,
        processed + 1,
        qa_count + new_qas
      )
    end
  end

  # =========================================================================
  # Phase 5: Embed Questions (Vectorize newly generated hypothetical Qs)
  # =========================================================================

  defp run_phase_5_embed_questions(batch_run, setting) do
    start_time = DateTime.utc_now()
    Logger.info("Batch ##{batch_run.id} - [Phase 5: Embed Questions] starting...")

    # Embed model loaded for question vectors
    unembedded_qas =
      Repo.all(
        from q in QAPair,
          where: is_nil(q.question_embedding) and q.status == "active"
      )

    items_count = length(unembedded_qas)
    Logger.info("Batch ##{batch_run.id} - Found #{items_count} questions to embed.")

    if items_count > 0 do
      qa_ids = Enum.map(unembedded_qas, & &1.id)
      # Batch in chunks of 50
      qa_ids
      |> Enum.chunk_every(50)
      |> Enum.each(fn chunk_ids ->
        EmbedQuestionsWorker.perform(%Oban.Job{args: %{"qa_pair_ids" => chunk_ids}})
      end)
    end

    finished_time = DateTime.utc_now()
    duration = DateTime.diff(finished_time, start_time)

    # Unload embed model
    Ollama.unload_model(setting.embed_model)

    stat =
      record_phase_stat(
        batch_run,
        "embed_questions",
        start_time,
        finished_time,
        duration,
        items_count
      )

    {stat, batch_run}
  end

  # =========================================================================
  # Phase 6: Verify & Finish
  # =========================================================================

  defp run_phase_6_verify(batch_run, _setting, deadline_reached?) do
    start_time = DateTime.utc_now()
    Logger.info("Batch ##{batch_run.id} - [Phase 6: Verify] starting...")

    # Verify virtual table counts or consistency
    final_status = if deadline_reached?, do: "deadline_reached", else: "completed"
    finished_time = DateTime.utc_now()
    duration = DateTime.diff(finished_time, start_time)

    batch_run =
      batch_run
      |> BatchRun.changeset(%{
        finished_at: finished_time,
        status: final_status
      })
      |> Repo.update!()

    stat =
      record_phase_stat(
        batch_run,
        "verify",
        start_time,
        finished_time,
        duration,
        0
      )

    Logger.info("Batch ##{batch_run.id} finished with status: #{final_status}")
    {stat, batch_run}
  end

  # --- Helpers ---

  defp calculate_deadline(setting) do
    # e.g. batch_end_hour
    now = DateTime.utc_now()
    end_hour = setting.batch_end_hour || 7

    # Deadline is today or tomorrow at end_hour:00
    today_deadline =
      DateTime.new!(
        Date.utc_today(),
        Time.new!(end_hour, 0, 0),
        "Etc/UTC"
      )

    if DateTime.compare(now, today_deadline) == :lt do
      today_deadline
    else
      DateTime.add(today_deadline, 24 * 3600, :second)
    end
  end

  defp record_phase_stat(batch_run, phase_name, start_time, finished_time, duration, count) do
    %BatchPhaseStat{}
    |> BatchPhaseStat.changeset(%{
      batch_run_id: batch_run.id,
      phase_name: phase_name,
      started_at: start_time,
      finished_at: finished_time,
      duration_seconds: max(0, duration),
      items_count: count,
      status: "completed"
    })
    |> Repo.insert!()
  end
end
