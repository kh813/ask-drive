defmodule AskDrive.Runtime.ToolInstallerTest do
  @moduledoc "Installing Ollama and pandoc from the platform admin screen (spec F-837, F-839)."
  use ExUnit.Case, async: false

  alias AskDrive.Runtime.ToolInstaller

  setup do
    on_exit(fn ->
      Application.delete_env(:ask_drive, :tool_install_command)
      # a fresh installer (idle) for the next test
      :ok = Supervisor.terminate_child(AskDrive.Supervisor, ToolInstaller)
      {:ok, _} = Supervisor.restart_child(AskDrive.Supervisor, ToolInstaller)
    end)

    Phoenix.PubSub.subscribe(AskDrive.PubSub, ToolInstaller.topic())
    :ok
  end

  defp command(script),
    do: Application.put_env(:ask_drive, :tool_install_command, {"/bin/sh", ["-c", script]})

  defp wait_finished do
    assert_receive {:tool_install, "ollama", %{status: status} = st}
                   when status in [:done, :failed],
                   5_000

    st
  end

  test "runs the install, keeping its output and the download's last progress" do
    command(~S"""
    echo "Ollama をダウンロードしています"
    printf '  10%%\r  55%%\r 100%%\n'
    echo "インストールしました"
    """)

    assert ToolInstaller.status("ollama").available?
    assert :ok = ToolInstaller.install("ollama", "admin@example.com")
    assert {:error, :busy} = ToolInstaller.install("ollama", "someone@example.com")

    st = wait_finished()
    assert st.status == :done
    assert st.by == "admin@example.com"
    assert st.log == ["Ollama をダウンロードしています", " 100%", "インストールしました"]
    assert ToolInstaller.status("ollama").status == :done
  end

  test "a failed install is reported with its output" do
    command(~S"echo 'zstd が必要です'; exit 1")

    assert :ok = ToolInstaller.install("ollama", "admin@example.com")
    st = wait_finished()
    assert st.status == :failed
    assert "zstd が必要です" in st.log
  end

  test "without app.sh (tests don't manage Ollama) it can't be installed from the screen" do
    refute ToolInstaller.status("ollama").available?
    assert {:error, :unavailable} = ToolInstaller.install("ollama", "admin@example.com")
  end
end
