defmodule AskDrive.Drive.Client do
  @moduledoc """
  Client for the Google Drive API v3 using `Req` and `AskDrive.Accounts` for tokens.
  Handles exponential backoff, rate limits (429/5xx), pagination, and recursive folder traversal.
  """
  require Logger
  alias AskDrive.Accounts

  @base_url "https://www.googleapis.com/drive/v3"
  @max_retries 5
  # test.exs sets 0 so the retry paths run without waiting out real backoffs
  @base_backoff_ms Application.compile_env(:ask_drive, :drive_base_backoff_ms, 1000)

  @doc """
  Gets metadata for a specific Drive file or folder.
  """
  def get_metadata(file_id) do
    fields = "id,name,mimeType,modifiedTime,size,md5Checksum,webViewLink,parents,trashed"
    url = "#{@base_url}/files/#{file_id}?fields=#{fields}&supportsAllDrives=true"
    request_with_retry(:get, url)
  end

  @doc """
  Recursively lists all non-folder, non-trashed files within a given folder ID.
  Returns `{:ok, [file_metadata_with_path]}` or `{:error, reason}`.
  """
  def list_files(folder_id) do
    case get_metadata(folder_id) do
      {:ok, root_folder} ->
        root_path = "/#{root_folder["name"] || "Root"}"
        traverse_folder(folder_id, root_path)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp traverse_folder(folder_id, current_path) do
    case list_folder_children(folder_id) do
      {:ok, items} ->
        {subfolders, files} =
          Enum.split_with(items, fn item ->
            item["mimeType"] == "application/vnd.google-apps.folder"
          end)

        # Map files with their virtual path
        mapped_files =
          Enum.map(files, fn file ->
            Map.put(file, "path", "#{current_path}/#{file["name"]}")
          end)

        # Recursively traverse subfolders
        subfolder_files_results =
          Enum.map(subfolders, fn subfolder ->
            sub_path = "#{current_path}/#{subfolder["name"]}"
            traverse_folder(subfolder["id"], sub_path)
          end)

        # Check for errors in subfolder traversal
        case Enum.find(subfolder_files_results, fn res -> match?({:error, _}, res) end) do
          nil ->
            all_sub_files =
              subfolder_files_results
              |> Enum.flat_map(fn {:ok, f_list} -> f_list end)

            {:ok, mapped_files ++ all_sub_files}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp list_folder_children(folder_id, page_token \\ nil, acc \\ []) do
    query = "'#{folder_id}' in parents and trashed = false"

    fields =
      "nextPageToken,files(id,name,mimeType,modifiedTime,size,md5Checksum,webViewLink,parents)"

    params = [
      q: query,
      pageSize: 1000,
      fields: fields,
      supportsAllDrives: true,
      includeItemsFromAllDrives: true
    ]

    params = if page_token, do: [{:pageToken, page_token} | params], else: params
    url = "#{@base_url}/files?" <> URI.encode_query(params)

    case request_with_retry(:get, url) do
      {:ok, %{"files" => files} = body} ->
        new_acc = acc ++ files
        next_token = body["nextPageToken"]

        if next_token do
          list_folder_children(folder_id, next_token, new_acc)
        else
          {:ok, new_acc}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Downloads binary content of a file (for non-Google Docs types like PDF, Office, TXT, CSV).
  """
  def download(file_id) do
    url = "#{@base_url}/files/#{file_id}?alt=media&supportsAllDrives=true"
    request_raw_with_retry(:get, url)
  end

  @doc """
  Exports a Google Workspace document (Docs, Sheets, Slides) to the specified MIME format.
  """
  def export(file_id, mime_type) do
    url =
      "#{@base_url}/files/#{file_id}/export?" <>
        URI.encode_query(%{mimeType: mime_type, supportsAllDrives: true})

    request_raw_with_retry(:get, url)
  end

  # --- Internal HTTP Helpers with Exponential Backoff ---

  defp request_with_retry(method, url, opts \\ [], attempt \\ 1) do
    with {:ok, token} <- Accounts.get_valid_access_token() do
      headers = [{"authorization", "Bearer #{token}"} | Keyword.get(opts, :headers, [])]
      req_opts = opts |> Keyword.put(:headers, headers)

      case send_request(method, url, req_opts) do
        {:ok, %{status: 200, body: body}} ->
          {:ok, body}

        {:ok, %{status: status, body: body}} when status in [429, 500, 502, 503, 504] ->
          if attempt < @max_retries do
            backoff_sleep(attempt)
            request_with_retry(method, url, opts, attempt + 1)
          else
            Logger.error("Drive API #{status} after #{@max_retries} attempts: #{inspect(body)}")
            {:error, "HTTP #{status}: #{inspect(body)}"}
          end

        {:ok, %{status: status, body: body}} ->
          {:error, "HTTP #{status}: #{inspect(body)}"}

        {:error, reason} ->
          if attempt < @max_retries do
            backoff_sleep(attempt)
            request_with_retry(method, url, opts, attempt + 1)
          else
            {:error, reason}
          end
      end
    end
  end

  defp request_raw_with_retry(method, url, opts \\ [], attempt \\ 1) do
    with {:ok, token} <- Accounts.get_valid_access_token() do
      headers = [{"authorization", "Bearer #{token}"} | Keyword.get(opts, :headers, [])]
      req_opts = opts |> Keyword.put(:headers, headers) |> Keyword.put(:raw, true)

      case send_request(method, url, req_opts) do
        {:ok, %{status: 200, body: body}} ->
          {:ok, body}

        {:ok, %{status: status, body: body}} when status in [429, 500, 502, 503, 504] ->
          if attempt < @max_retries do
            backoff_sleep(attempt)
            request_raw_with_retry(method, url, opts, attempt + 1)
          else
            {:error, "HTTP #{status}: #{inspect(body)}"}
          end

        {:ok, %{status: status, body: body}} ->
          {:error, "HTTP #{status}: #{inspect(body)}"}

        {:error, reason} ->
          if attempt < @max_retries do
            backoff_sleep(attempt)
            request_raw_with_retry(method, url, opts, attempt + 1)
          else
            {:error, reason}
          end
      end
    end
  end

  # Finch can raise out of a request instead of returning an error: a pooled keep-alive
  # connection still holding a late response to an earlier request fails its response match
  # with a CaseClauseError ({:status, other_ref, 200}). Treat that like a network error so it
  # gets the backoff retries (the pool drops the connection, the retry gets a fresh one)
  # rather than failing the document for the night.
  defp send_request(method, url, req_opts) do
    Req.request(
      [method: method, url: url] ++
        req_opts ++ Application.get_env(:ask_drive, :drive_req_options, [])
    )
  rescue
    e ->
      Logger.warning("Drive API request raised: #{Exception.message(e)}")
      {:error, {:exception, Exception.message(e)}}
  end

  defp backoff_sleep(attempt) do
    jitter = if @base_backoff_ms > 0, do: :rand.uniform(500), else: 0
    sleep_ms = (@base_backoff_ms * :math.pow(2, attempt - 1) + jitter) |> round()

    Logger.warning(
      "Drive API rate limit or server error. Retrying in #{sleep_ms}ms (attempt #{attempt}/#{@max_retries})..."
    )

    Process.sleep(sleep_ms)
  end
end
