defmodule AskDrive.LLM.OllamaInstallerTest do
  @moduledoc "Installing Ollama from the platform admin screen (spec F-837)."
  use ExUnit.Case, async: false

  alias AskDrive.LLM.OllamaInstaller

  setup do
    on_exit(fn ->
      Application.delete_env(:ask_drive, :ollama_install_command)
      # a fresh installer (idle) for the next test
      :ok = Supervisor.terminate_child(AskDrive.Supervisor, OllamaInstaller)
      {:ok, _} = Supervisor.restart_child(AskDrive.Supervisor, OllamaInstaller)
    end)

    Phoenix.PubSub.subscribe(AskDrive.PubSub, OllamaInstaller.topic())
    :ok
  end

  defp command(script),
    do: Application.put_env(:ask_drive, :ollama_install_command, {"/bin/sh", ["-c", script]})

  defp wait_finished do
    assert_receive {:ollama_install, %{status: status} = st} when status in [:done, :failed],
                   5_000

    st
  end

  test "runs the install, keeping its output and the download's last progress" do
    command(~S"""
    echo "Ollama をダウンロードしています"
    printf '  10%%\r  55%%\r 100%%\n'
    echo "インストールしました"
    """)

    assert OllamaInstaller.status().available?
    assert :ok = OllamaInstaller.install("admin@example.com")
    assert {:error, :busy} = OllamaInstaller.install("someone@example.com")

    st = wait_finished()
    assert st.status == :done
    assert st.by == "admin@example.com"
    assert st.log == ["Ollama をダウンロードしています", " 100%", "インストールしました"]
    assert OllamaInstaller.status().status == :done
  end

  test "a failed install is reported with its output" do
    command(~S"echo 'zstd が必要です'; exit 1")

    assert :ok = OllamaInstaller.install("admin@example.com")
    st = wait_finished()
    assert st.status == :failed
    assert "zstd が必要です" in st.log
  end

  test "without app.sh (tests don't manage Ollama) it can't be installed from the screen" do
    refute OllamaInstaller.status().available?
    assert {:error, :unavailable} = OllamaInstaller.install("admin@example.com")
  end
end
