defmodule AskDrive.Runtime.Tools do
  @moduledoc """
  The external programs AskDrive uses, for the platform admin screen's 「インストールとアップデート」
  tab (spec F-839): whether each is installed (where, which version), what it's for, and how
  to install it — from the screen when AskDrive can place it itself in `.runtime` (pandoc;
  Ollama has its own card), or else the commands to run on the server, for this OS and its
  package manager (the system's packages need root, which AskDrive doesn't have).
  """
  use Gettext, backend: AskDriveWeb.Gettext

  @doc """
  `[%{id, name, purpose, path, version, needed?, installer, commands}]`: `installer` is the
  tool `AskDrive.Runtime.ToolInstaller` installs it as (or nil), `commands` the terminal
  commands that install it here (`[]` when there is no known way for this system).
  """
  def list do
    pm = package_manager()

    [
      %{
        id: "pdftotext",
        name: "pdftotext",
        purpose: gettext("PDF text extraction (poppler)"),
        needed?: true,
        installer: nil,
        commands: commands(pm, %{apt: "poppler-utils", dnf: "poppler-utils", brew: "poppler"})
      },
      %{
        id: "pandoc",
        name: "pandoc",
        purpose: gettext("Text of Word, Excel and PowerPoint files"),
        needed?: true,
        installer: "pandoc",
        commands: commands(pm, %{apt: "pandoc", dnf: "pandoc", brew: "pandoc"})
      },
      %{
        id: "libreoffice",
        name: "LibreOffice",
        purpose: gettext("Old Word, Excel and PowerPoint files (.doc, .xls, .ppt)"),
        needed?: true,
        installer: nil,
        commands:
          commands(pm, %{
            apt:
              "--no-install-recommends libreoffice-writer libreoffice-calc libreoffice-impress",
            dnf: "libreoffice-writer libreoffice-calc libreoffice-impress",
            brew: "--cask libreoffice"
          })
      },
      %{
        id: "zstd",
        name: "zstd",
        purpose: gettext("Unpacking Ollama's download (Linux only)"),
        # Ollama's macOS download is a .tgz
        needed?: pm != :brew,
        installer: nil,
        commands: commands(pm, %{apt: "zstd", dnf: "zstd", brew: nil})
      }
    ]
    |> Enum.map(fn tool ->
      path = find(tool.id)
      Map.merge(tool, %{path: path, version: path && version(tool.id, path)})
    end)
  end

  @doc """
  For every tool now installed, puts back in every desk's queue the documents skipped for its
  lack (`Documents.requeue_missing_tool/1`). Returns how many in all.
  """
  def requeue_skipped(tools \\ list()) do
    installed =
      for tool <- tools, tool.path, tool.id in ~w(pdftotext pandoc libreoffice), do: tool.id

    AskDrive.Apps.each(fn _app ->
      installed |> Enum.map(&AskDrive.Documents.requeue_missing_tool/1) |> Enum.sum()
    end)
    |> Enum.map(fn {_app, count} -> count end)
    |> Enum.sum()
  end

  @doc """
  LibreOffice's command (`soffice`, also installed as `libreoffice`; on macOS inside the
  app), or nil. It converts .doc / .xls / .ppt for reading (spec F-356).
  """
  def libreoffice_path do
    System.find_executable("soffice") || System.find_executable("libreoffice") ||
      Enum.find(["/Applications/LibreOffice.app/Contents/MacOS/soffice"], &File.exists?/1)
  end

  defp find("libreoffice"), do: libreoffice_path()
  defp find(id), do: System.find_executable(id)

  @doc "The system's package manager: `:apt`, `:dnf`, `:brew` (macOS) or nil."
  def package_manager do
    cond do
      match?({:unix, :darwin}, :os.type()) -> :brew
      System.find_executable("apt-get") -> :apt
      System.find_executable("dnf") -> :dnf
      true -> nil
    end
  end

  defp commands(:apt, %{apt: pkg}) when is_binary(pkg),
    do: ["sudo apt-get update", "sudo apt-get install -y #{pkg}"]

  defp commands(:dnf, %{dnf: pkg}) when is_binary(pkg), do: ["sudo dnf install -y #{pkg}"]
  defp commands(:brew, %{brew: pkg}) when is_binary(pkg), do: ["brew install #{pkg}"]
  defp commands(_pm, _packages), do: []

  # the first line the program prints about its version (pdftotext prints it on stderr)
  defp version(id, path) do
    args = if id == "pdftotext", do: ["-v"], else: ["--version"]

    case System.cmd(path, args, stderr_to_stdout: true) do
      {out, _code} -> out |> String.split("\n", trim: true) |> List.first()
    end
  rescue
    _ -> nil
  end
end
