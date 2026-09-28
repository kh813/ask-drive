defmodule Mix.Tasks.AskDrive.SetAdminPassword do
  @shortdoc "Sets the shared administrator elevation password"

  @moduledoc """
  Sets the administrator password used to elevate a session (spec 6.9 F-920).

      mix ask_drive.set_admin_password

  Prompts twice without echoing. Pass the password as an argument only in a non-interactive
  context, and be aware that it will land in the shell history:

      mix ask_drive.set_admin_password "correct horse battery staple"

  Unlike the admin screen this does not require the current password, because the reason to
  reach for it is that nobody knows it any more. It only rewrites the stored digest — the
  plaintext is never persisted.
  """
  use Mix.Task

  alias AskDrive.Accounts.AdminAccess

  @impl Mix.Task
  def run(args) do
    AskDrive.CliTask.run(fn -> run_task(args) end)
  end

  defp run_task([password]), do: store(password)

  defp run_task([]) do
    password = prompt("新しい管理者パスワード: ")
    confirmation = prompt("確認のためもう一度: ")

    if password == confirmation do
      store(password)
    else
      Mix.raise("パスワードが一致しません。")
    end
  end

  defp run_task(_args), do: Mix.raise("使用方法: mix ask_drive.set_admin_password [password]")

  defp store(password) do
    case AdminAccess.force_set_password(password) do
      {:ok, _setting} ->
        Mix.shell().info("管理者パスワードを設定しました。")

      {:error, :too_short} ->
        Mix.raise("パスワードは #{AdminAccess.min_password_length()} 文字以上にしてください。")

      {:error, :surrounding_whitespace} ->
        Mix.raise("パスワードの前後に空白を含めないでください。")

      {:error, reason} ->
        Mix.raise("管理者パスワードを設定できませんでした: #{inspect(reason)}")
    end
  end

  # Mix.shell().prompt/1 echoes what is typed. Turn the terminal echo off around the read so
  # the password does not end up on screen or in a scrollback buffer. `</dev/tty` is needed
  # because an Erlang port does not inherit the controlling terminal.
  defp prompt(message) do
    IO.write(message)
    stty("-echo")

    value =
      case IO.gets("") do
        :eof -> ""
        {:error, _} -> ""
        line -> line |> to_string() |> String.trim_trailing("\n")
      end

    stty("echo")
    IO.write("\n")
    value
  end

  defp stty(flag) do
    System.cmd("sh", ["-c", "stty #{flag} </dev/tty"], stderr_to_stdout: true)
    :ok
  rescue
    _ -> :ok
  end
end
