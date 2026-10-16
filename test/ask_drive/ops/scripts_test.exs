defmodule AskDrive.Ops.ScriptsTest do
  use ExUnit.Case, async: true

  @root_dir Path.expand("../../..", __DIR__)
  @app_sh Path.join(@root_dir, "app.sh")
  @initial_setup_sh Path.join([@root_dir, "scripts", "initial-setup.sh"])
  @deploy_sh Path.join([@root_dir, "scripts", "deploy.sh"])
  @runtime_exs Path.join([@root_dir, "config", "runtime.exs"])
  @release_yml Path.join([@root_dir, ".github", "workflows", "release.yml"])
  @platform_sh Path.join([@root_dir, "scripts", "lib", "platform.sh"])

  describe "Script syntax validation" do
    test "app.sh, initial-setup.sh, deploy.sh and platform.sh have valid bash syntax" do
      for script <- [@app_sh, @initial_setup_sh, @deploy_sh, @platform_sh] do
        assert File.exists?(script), "Script does not exist: #{script}"
        {output, exit_code} = System.cmd("bash", ["-n", script], stderr_to_stdout: true)
        assert exit_code == 0, "Bash syntax error in #{Path.basename(script)}:\n#{output}"
      end
    end
  end

  describe "GitHub Release and version parsing regression tests" do
    test "extracts clean version string from GitHub API JSON using macOS BSD sed regex" do
      sample_json = ~s|{"tag_name": "v0.0.8", "name": "AskDrive v0.0.8"}|

      # Run the exact grep & sed expression used in app.sh
      command =
        "echo '#{sample_json}' | grep '\"tag_name\":' | sed -E 's/.*\"tag_name\": *\"v?([^\"]+)\".*/\\1/'"

      {output, exit_code} = System.cmd("bash", ["-c", command])
      assert exit_code == 0
      assert String.trim(output) == "0.0.8"
    end

    test "handles tags with or without leading v" do
      for tag <- ["v0.0.8", "0.0.8", "v1.2.3"] do
        sample_json = ~s|{"tag_name": "#{tag}"}|

        command =
          "echo '#{sample_json}' | grep '\"tag_name\":' | sed -E 's/.*\"tag_name\": *\"v?([^\"]+)\".*/\\1/'"

        {output, exit_code} = System.cmd("bash", ["-c", command])
        assert exit_code == 0
        expected = String.trim_leading(tag, "v")
        assert String.trim(output) == expected
      end
    end

    test "app.sh strips leading v from user-specified --ver argument" do
      app_content = File.read!(@app_sh)
      assert app_content =~ ~s(download_ver="${download_ver#v}")
      assert app_content =~ ~s(download_ver="${download_ver#V}")
    end
  end

  describe "External binary URL and archive naming regression tests" do
    test "pandoc assets: .zip on macOS, .tar.gz on Linux (amd64 / arm64)" do
      platform = File.read!(@platform_sh)
      assert platform =~ "pandoc-${ver}-arm64-macOS.zip"
      assert platform =~ "pandoc-${ver}-x86_64-macOS.zip"
      assert platform =~ "pandoc-${ver}-linux-amd64.tar.gz"
      assert platform =~ "pandoc-${ver}-linux-arm64.tar.gz"
    end

    test "sqlite-vec URL has no extra v prefix in the file name, for macOS and Linux" do
      platform = File.read!(@platform_sh)
      assert platform =~ "download/v${ver}/sqlite-vec-${ver}-loadable-${os}-${arch}.tar.gz"
      refute platform =~ "sqlite-vec-v${ver}-loadable"
    end

    test "Ollama: flat .tgz into .runtime/bin on macOS, .tar.zst (bin/ + lib/ollama) on Linux" do
      platform = File.read!(@platform_sh)
      assert platform =~ "https://ollama.com/download/ollama-darwin.tgz"
      assert platform =~ "https://ollama.com/download/ollama-linux-${arch}.tar.zst"
      assert platform =~ ~s(-d "${RUNTIME_DIR}/lib/ollama")
    end

    test "release.yml packaging uses correct sqlite-vec URL and extracts vec0.dylib cleanly" do
      release_content = File.read!(@release_yml)
      assert release_content =~ "sqlite-vec-0.1.9-loadable-macos-aarch64.tar.gz"
      assert release_content =~ "tar -xzf /tmp/sqlite-vec.tar.gz -C /tmp"
      assert release_content =~ "cp /tmp/vec0.dylib priv/sqlite_vec/vec0.dylib"
    end

    test "release.yml excludes internal dev specs and test suites" do
      release_content = File.read!(@release_yml)
      assert release_content =~ ~s(-x "ask-drive-spec.md")
      assert release_content =~ ~s(-x "ask-drive-todo.md")
      assert release_content =~ ~s(-x "test/*")
    end
  end

  describe "Secret generation and non-blocking initialization" do
    test "secret generation uses openssl/urandom and does not call mix tasks before deps.get" do
      setup_content = File.read!(@initial_setup_sh)
      # Must not call mix phx.gen.secret in initial-setup before dependencies are compiled
      refute setup_content =~ "mix phx.gen.secret"
      refute setup_content =~ "mix ask_drive.gen.key"
      assert setup_content =~ "openssl rand -base64"
    end

    test "generates valid Base64 encryption key decodeable by TokenVault" do
      # Test secret generation command
      {secret_out, 0} = System.cmd("bash", ["-c", "openssl rand -base64 48 | tr -d '\\n'"])
      {key_out, 0} = System.cmd("bash", ["-c", "openssl rand -base64 32 | tr -d '\\n'"])

      assert String.length(secret_out) >= 64
      assert {:ok, decoded} = Base.decode64(key_out)
      assert byte_size(decoded) == 32
    end
  end

  describe "Environment variable loading and deploy fallback regression tests" do
    test "deploy.sh restarts the service (launchd or systemd) when registered, else starts in the foreground" do
      deploy_content = File.read!(@deploy_sh)
      assert deploy_content =~ ~s("${SCRIPT_DIR}/app.sh" service registered)
      assert deploy_content =~ ~s("${SCRIPT_DIR}/app.sh" service restart)
      # The foreground start must not run first (it blocks the deploy for a daemonised install)
      refute deploy_content =~
               ~s("${SCRIPT_DIR}/app.sh" restart || "${SCRIPT_DIR}/app.sh" service restart)
    end

    test "deploy.sh sources .env.prod and falls back to initial-setup.sh if not prepared" do
      deploy_content = File.read!(@deploy_sh)
      assert deploy_content =~ ~s(source "${SCRIPT_DIR}/.env.prod")
      assert deploy_content =~ "initial-setup.sh"
    end

    test "config/runtime.exs provides safe build fallbacks for DATABASE_PATH and SECRET_KEY_BASE" do
      runtime_content = File.read!(@runtime_exs)
      assert runtime_content =~ ~s[System.get_env("DATABASE_PATH") ||]
      assert runtime_content =~ ~s[System.get_env("SECRET_KEY_BASE") ||]
      refute runtime_content =~ "environment variable DATABASE_PATH is missing"
    end

    test "PATH in scripts and launchd service includes .runtime directories" do
      app_content = File.read!(@app_sh)
      assert app_content =~ ~s(${RUNTIME_BIN}:${RUNTIME_BREW}/bin)
      assert app_content =~ ~s(${SCRIPT_DIR}/.runtime/bin:${SCRIPT_DIR}/.runtime/homebrew/bin)

      setup_content = File.read!(@initial_setup_sh)
      assert setup_content =~ ~s(${RUNTIME_BIN}:${RUNTIME_BREW}/bin)

      deploy_content = File.read!(@deploy_sh)
      assert deploy_content =~ ~s(${RUNTIME_BIN}:${RUNTIME_BREW}/bin)
    end

    test "config/prod.exs and config/runtime.exs are configured for direct LAN access without SSL redirect loop" do
      prod_config = File.read!(Path.join([@root_dir, "config", "prod.exs"]))
      refute prod_config =~ "force_ssl:"

      runtime_config = File.read!(@runtime_exs)
      assert runtime_config =~ ~s(scheme: "http")
      assert runtime_config =~ "check_origin: false"
      assert runtime_config =~ "ip: {0, 0, 0, 0, 0, 0, 0, 0}"
    end

    test "app.sh auto-starts Ollama if not running before launching server" do
      app_content = File.read!(@app_sh)
      assert app_content =~ "ollama serve"
      assert app_content =~ "curl -s \"${ollama_host}/api/tags\""
    end
  end

  test "a release fails unless mix.exs carries the tag's version (shown on the dashboard)" do
    assert File.read!(@release_yml) =~ "Check mix.exs version matches the tag"
    assert File.read!(@app_sh) =~ "インストール済みバージョン"
  end

  test "initial setup: LLM keys can wait; Ollama only when it is chosen (F-343)" do
    setup = File.read!(@initial_setup_sh)
    # a key left blank is fine, and the end of the setup says where to register it
    assert setup =~ "空欄のまま Enter で進めます"
    assert setup =~ "API キーは未登録です"
    # the embedding default follows the generation provider (no silent Ollama on a cloud setup)
    assert setup =~ "gemini) DEFAULT_EMB_CHOICE=3"
    # Ollama is installed in step 4, only in the branch that needs it
    [before_step4, step4] = String.split(setup, "[4/7] Ollama サービスとモデルの確認中", parts: 2)
    refute before_step4 =~ ~r/^ensure_ollama_runtime$/m
    assert step4 =~ "ensure_ollama_runtime"
    assert setup =~ "./app.sh repair-ollama"
  end

  describe "platform.sh (macOS / Linux)" do
    test "detects the OS and architecture of this machine" do
      out = run_platform(~s|echo "$ASKDRIVE_OS $ASKDRIVE_ARCH $(sqlite_vec_filename)"|)
      [os, arch, vec] = String.split(String.trim(out))
      assert os in ["macos", "linux"]
      assert arch in ["arm64", "x86_64"]
      assert vec == if(os == "macos", do: "vec0.dylib", else: "vec0.so")
    end

    test "sed_inplace edits in place with this machine's sed (BSD or GNU), leaving no backup" do
      dir = Path.join(System.tmp_dir!(), "askdrive_sed_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      file = Path.join(dir, "f.txt")
      File.write!(file, "PORT=4000\n")

      run_platform(~s(sed_inplace 's/PORT=4000/PORT=4080/' "#{file}"))

      assert File.read!(file) == "PORT=4080\n"
      assert File.ls!(dir) == ["f.txt"]
      File.rm_rf!(dir)
    end

    test "the systemd unit runs app.sh start as the given user, with .runtime on PATH" do
      unit = run_platform(~s(systemd_unit_content /opt/askdrive askdrive askdrive /home/askdrive))
      assert unit =~ "ExecStart=/opt/askdrive/app.sh start"
      assert unit =~ "User=askdrive"
      assert unit =~ "WorkingDirectory=/opt/askdrive"
      assert unit =~ "/opt/askdrive/.runtime/otp/bin"
      assert unit =~ "Restart=on-failure"
      assert unit =~ "WantedBy=multi-user.target"
    end

    test "the sudoers rule allows only start/stop/restart of the askdrive unit" do
      rule =
        run_platform(~s(systemd_sudoers_content askdrive /usr/bin/systemctl askdrive.service))

      assert rule =~
               "askdrive ALL=(root) NOPASSWD: /usr/bin/systemctl start askdrive.service, /usr/bin/systemctl stop askdrive.service, /usr/bin/systemctl restart askdrive.service"

      refute rule =~ "ALL=(ALL)"
    end
  end

  defp run_platform(snippet) do
    script = """
    set -euo pipefail
    RUNTIME_DIR="$(mktemp -d)"
    RUNTIME_BIN="${RUNTIME_DIR}/bin"
    source "#{@platform_sh}"
    #{snippet}
    """

    {out, 0} = System.cmd("bash", ["-c", script], stderr_to_stdout: true)
    out
  end
end
