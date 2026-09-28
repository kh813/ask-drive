defmodule AskDrive.Ops.ScriptsTest do
  use ExUnit.Case, async: true

  @root_dir Path.expand("../../..", __DIR__)
  @app_sh Path.join(@root_dir, "app.sh")
  @initial_setup_sh Path.join([@root_dir, "scripts", "initial-setup.sh"])
  @deploy_sh Path.join([@root_dir, "scripts", "deploy.sh"])
  @runtime_exs Path.join([@root_dir, "config", "runtime.exs"])
  @release_yml Path.join([@root_dir, ".github", "workflows", "release.yml"])

  describe "Script syntax validation" do
    test "app.sh, initial-setup.sh, and deploy.sh have valid bash syntax" do
      for script <- [@app_sh, @initial_setup_sh, @deploy_sh] do
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
    test "initial-setup.sh uses correct archive format (.zip) for pandoc" do
      setup_content = File.read!(@initial_setup_sh)
      assert setup_content =~ "pandoc-${PANDOC_VER}-arm64-macOS.zip"
      assert setup_content =~ "pandoc-${PANDOC_VER}-x86_64-macOS.zip"
      refute setup_content =~ "pandoc-${PANDOC_VER}-macOS-${ARCH}.tar.gz"
    end

    test "initial-setup.sh uses correct sqlite-vec URL without extra v prefix in filename" do
      setup_content = File.read!(@initial_setup_sh)
      assert setup_content =~ "sqlite-vec-0.1.9-loadable-macos-aarch64.tar.gz"
      refute setup_content =~ "sqlite-vec-v0.1.9-loadable-macos-aarch64.tar.gz"
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
end
