defmodule AskDrive.Repo do
  use Ecto.Repo,
    otp_app: :ask_drive,
    adapter: Ecto.Adapters.SQLite3

  @doc """
  Dynamically resolves the sqlite-vec extension path.
  """
  def sqlite_vec_path do
    priv_dir = :code.priv_dir(:ask_drive) |> to_string()
    Path.join([priv_dir, "sqlite_vec", "vec0"])
  rescue
    _ ->
      Path.expand("priv/sqlite_vec/vec0", File.cwd!())
  end

  @impl true
  def init(_type, config) do
    vec_path = sqlite_vec_path()
    extensions = Keyword.get(config, :load_extensions, [])

    # Append sqlite-vec path if exists
    extensions =
      if File.exists?(vec_path <> ".dylib") or File.exists?(vec_path <> ".so") do
        [vec_path | extensions] |> Enum.uniq()
      else
        extensions
      end

    config =
      config
      |> Keyword.put(:load_extensions, extensions)
      |> Keyword.put_new(:journal_mode, :wal)
      |> Keyword.put_new(:cache_size, -64000)
      |> Keyword.put_new(:busy_timeout, 5000)

    {:ok, config}
  end
end
