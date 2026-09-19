defmodule SymphonyElixir.EnvironmentCapabilitiesTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.Schema.EnvironmentCapability

  test "no declarations produce an explicit not_checked report" do
    workspace = temporary_workspace("no-declarations")
    File.mkdir_p!(workspace)

    assert {:ok, report} = EnvironmentCapabilities.verify(workspace)
    assert report["status"] == "not_checked"
    assert report["capabilities"] == []
    assert report["workspace"] == Path.expand(workspace)
    assert is_binary(report["configuration_digest"])
    assert is_binary(report["verified_at"])
  end

  test "verifies the canonical executable and nested resources without exposing command output" do
    workspace = temporary_workspace("gh8-shape")
    empty_path = Path.join(workspace, "empty-path")
    executable = Path.join([workspace, ".venv", "bin", "python"])

    resource_paths = [
      "fixtures/einstein/Einstein, Albert - Relativity 10.pdf",
      "fixtures/mccarthy/McCarthy, Cormac - Stella Maris.pt2 18.pdf"
    ]

    File.mkdir_p!(Path.dirname(executable))
    File.mkdir_p!(empty_path)

    Enum.each(resource_paths, fn resource ->
      path = Path.join(workspace, resource)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "fixture")
    end)

    File.write!(executable, "#!/bin/sh\nprintf '%s' \"$CAPABILITY_SECRET\"\n")
    File.chmod!(executable, 0o755)

    previous_path = System.get_env("PATH")
    previous_secret = System.get_env("CAPABILITY_SECRET")
    System.put_env("PATH", empty_path)
    System.put_env("CAPABILITY_SECRET", "must-not-cross-prompt-boundary")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("CAPABILITY_SECRET", previous_secret)
    end)

    write_instance_config_file!(InstanceConfig.instance_config_file_path(),
      environment_capabilities: [
        %{
          "id" => "project-runtime",
          "command" => %{
            "executable" => ".venv/bin/python",
            "args" => ["-c", "import fitz, PIL"]
          },
          "resources" => resource_paths,
          "working_directory" => "."
        }
      ]
    )

    assert is_nil(System.find_executable("python"))
    assert {:ok, report} = EnvironmentCapabilities.verify(workspace)
    assert report["status"] == "verified"

    [capability] = report["capabilities"]
    assert capability["id"] == "project-runtime"
    assert capability["status"] == "verified"
    assert capability["command"]["executable"] == ".venv/bin/python"
    assert capability["resources"] == resource_paths
    refute Jason.encode!(report) =~ "must-not-cross-prompt-boundary"
    refute Jason.encode!(report) =~ "import fitz"
    refute File.exists?(Path.join(workspace, "Einstein, Albert - Relativity 10.pdf"))
  end

  test "missing resources fail closed as unavailable" do
    workspace = temporary_workspace("missing-resource")
    File.mkdir_p!(workspace)

    write_instance_config_file!(InstanceConfig.instance_config_file_path(),
      environment_capabilities: [
        %{
          "id" => "required-fixtures",
          "resources" => ["fixtures/nested/required.pdf"]
        }
      ]
    )

    assert {:error, {:environment_capability_verification_failed, report}} =
             EnvironmentCapabilities.verify(workspace)

    assert report["status"] == "failed"
    assert [%{"status" => "unavailable", "observed" => observed}] = report["capabilities"]
    assert observed["available"] == false
  end

  test "a failed command is not reported as verified" do
    workspace = temporary_workspace("failed-command")
    File.mkdir_p!(workspace)

    write_instance_config_file!(InstanceConfig.instance_config_file_path(),
      environment_capabilities: [
        %{
          "id" => "failing-tool",
          "command" => %{"executable" => "false", "args" => []}
        }
      ]
    )

    assert {:error, {:environment_capability_verification_failed, report}} =
             EnvironmentCapabilities.verify(workspace)

    assert report["status"] == "failed"
    assert [%{"status" => "failed", "observed" => %{"exit_status" => 1}}] = report["capabilities"]
  end

  test "an unavailable executable is distinguished from a failed command" do
    workspace = temporary_workspace("missing-executable")
    File.mkdir_p!(workspace)

    write_instance_config_file!(InstanceConfig.instance_config_file_path(),
      environment_capabilities: [
        %{
          "id" => "missing-tool",
          "command" => %{"executable" => "symphony-command-that-does-not-exist"}
        }
      ]
    )

    assert {:error, {:environment_capability_verification_failed, report}} =
             EnvironmentCapabilities.verify(workspace)

    assert [%{"status" => "unavailable", "observed" => %{"command_executed" => false}}] =
             report["capabilities"]
  end

  test "runtime symlink escapes fail as verification errors" do
    workspace = temporary_workspace("symlink-escape")
    outside = temporary_workspace("outside")
    outside_tool = Path.join(outside, "tool")
    File.mkdir_p!(workspace)
    File.mkdir_p!(outside)
    File.write!(outside_tool, "#!/bin/sh\nexit 0\n")
    File.chmod!(outside_tool, 0o755)
    File.ln_s!(outside, Path.join(workspace, "external"))

    write_instance_config_file!(InstanceConfig.instance_config_file_path(),
      environment_capabilities: [
        %{"id" => "escaped-resource", "resources" => ["external"]},
        %{
          "id" => "escaped-command",
          "command" => %{"executable" => "external/tool"}
        }
      ]
    )

    assert {:error, {:environment_capability_verification_failed, report}} =
             EnvironmentCapabilities.verify(workspace)

    assert Enum.all?(report["capabilities"], fn capability ->
             capability["status"] == "failed" and
               capability["observed"]["error"] == "verification_error"
           end)
  end

  test "a verification timeout is a failed required check" do
    workspace = temporary_workspace("timeout")
    File.mkdir_p!(workspace)

    write_instance_config_file!(InstanceConfig.instance_config_file_path(),
      hook_timeout_ms: 10,
      environment_capabilities: [
        %{
          "id" => "slow-tool",
          "command" => %{"executable" => "sleep", "args" => ["1"]}
        }
      ]
    )

    assert {:error, {:environment_capability_verification_failed, report}} =
             EnvironmentCapabilities.verify(workspace)

    assert [%{"status" => "failed", "observed" => %{"timeout_ms" => 10}}] = report["capabilities"]
  end

  test "unsafe declarations are rejected before verification" do
    write_instance_config_file!(InstanceConfig.instance_config_file_path(),
      environment_capabilities: [
        %{
          "id" => "unsafe-resource",
          "resources" => ["../outside.txt"]
        }
      ]
    )

    assert {:error, {:invalid_instance_config_config, message}} = Config.validate!()
    assert message =~ "environment.capabilities"
  end

  test "duplicate identifiers and empty checks are rejected" do
    write_instance_config_file!(InstanceConfig.instance_config_file_path(),
      environment_capabilities: [
        %{"id" => "duplicate", "resources" => ["one"]},
        %{"id" => "duplicate", "resources" => ["two"]}
      ]
    )

    assert {:error, {:invalid_instance_config_config, duplicate_message}} = Config.validate!()
    assert duplicate_message =~ "environment.capabilities"

    write_instance_config_file!(InstanceConfig.instance_config_file_path(),
      environment_capabilities: [%{"id" => "empty"}]
    )

    assert {:error, {:invalid_instance_config_config, empty_message}} = Config.validate!()
    assert empty_message =~ "environment.capabilities"

    write_instance_config_file!(InstanceConfig.instance_config_file_path(),
      environment_capabilities: [
        %{
          "id" => "unsafe-command",
          "command" => %{"executable" => "/bin/sh", "args" => []}
        }
      ]
    )

    assert {:error, {:invalid_instance_config_config, command_message}} = Config.validate!()
    assert command_message =~ "environment.capabilities"

    write_instance_config_file!(InstanceConfig.instance_config_file_path(),
      environment_capabilities: [
        %{
          "id" => "unknown-command-field",
          "command" => %{"executable" => "true", "unexpected" => "value"}
        }
      ]
    )

    assert {:error, {:invalid_instance_config_config, unknown_field_message}} = Config.validate!()
    assert unknown_field_message =~ "environment.capabilities"

    write_instance_config_file!(InstanceConfig.instance_config_file_path(),
      environment_capabilities: [
        %{
          "id" => "unsafe-working-directory",
          "working_directory" => "../outside",
          "resources" => ["resource"]
        }
      ]
    )

    assert {:error, {:invalid_instance_config_config, directory_message}} = Config.validate!()
    assert directory_message =~ "environment.capabilities"

    changeset =
      EnvironmentCapability.changeset(
        %EnvironmentCapability{},
        %{"id" => "invalid-command", "command" => "not-a-map"}
      )

    refute changeset.valid?
  end

  test "a fresh dispatch re-verifies the workspace instead of reusing an earlier report" do
    workspace = temporary_workspace("fresh-report")
    resource = "fixtures/nested/required.pdf"
    File.mkdir_p!(Path.join(workspace, "fixtures/nested"))
    File.write!(Path.join(workspace, resource), "fixture")

    write_instance_config_file!(InstanceConfig.instance_config_file_path(),
      environment_capabilities: [%{"id" => "required-fixture", "resources" => [resource]}]
    )

    assert {:ok, first_report} = EnvironmentCapabilities.verify(workspace)
    File.rm!(Path.join(workspace, resource))

    assert {:error, {:environment_capability_verification_failed, second_report}} =
             EnvironmentCapabilities.verify(workspace)

    assert first_report["status"] == "verified"
    assert second_report["status"] == "failed"
    assert first_report["configuration_digest"] == second_report["configuration_digest"]
  end

  test "the report identity changes when its workspace or declaration changes" do
    first_workspace = temporary_workspace("identity-first")
    second_workspace = temporary_workspace("identity-second")
    resource = "fixtures/nested/required.pdf"

    for workspace <- [first_workspace, second_workspace] do
      File.mkdir_p!(Path.join(workspace, "fixtures/nested"))
      File.write!(Path.join(workspace, resource), "fixture")
    end

    write_instance_config_file!(InstanceConfig.instance_config_file_path(),
      environment_capabilities: [%{"id" => "required-fixture", "resources" => [resource]}]
    )

    assert {:ok, first_report} = EnvironmentCapabilities.verify(first_workspace)
    assert {:ok, second_report} = EnvironmentCapabilities.verify(second_workspace)
    assert first_report["workspace"] != second_report["workspace"]
    assert first_report["configuration_digest"] == second_report["configuration_digest"]

    write_instance_config_file!(InstanceConfig.instance_config_file_path(),
      environment_capabilities: [%{"id" => "different-fixture", "resources" => [resource]}]
    )

    assert {:ok, changed_report} = EnvironmentCapabilities.verify(second_workspace)
    assert changed_report["workspace"] == second_report["workspace"]
    refute changed_report["configuration_digest"] == second_report["configuration_digest"]
  end

  test "required verification failure prevents the Codex process from starting" do
    workspace_root = temporary_workspace("fail-closed-dispatch")

    issue = %Issue{
      id: "issue-capability-failure",
      identifier: "CAP-FAIL",
      title: "Capability failure",
      description: "Must not launch",
      state: "In Progress"
    }

    write_instance_config_file!(InstanceConfig.instance_config_file_path(),
      workspace_root: workspace_root,
      environment_capabilities: [%{"id" => "missing", "resources" => ["missing.txt"]}]
    )

    assert_raise RuntimeError, ~r/environment_capability_verification_failed/, fn ->
      AgentRunner.run(issue, nil, role: :reviewer)
    end
  end

  test "the verified report reaches the Codex turn boundary without changing role authority" do
    test_root = temporary_workspace("codex-boundary")
    workspace = Path.join(test_root, "CAP-BOUNDARY")
    codex_binary = Path.join(test_root, "fake-codex")
    trace_file = Path.join(test_root, "codex.trace")
    executable = Path.join([workspace, ".venv", "bin", "python"])
    resource = "fixtures/nested/required.pdf"

    File.mkdir_p!(Path.dirname(executable))
    File.mkdir_p!(Path.join(workspace, "fixtures/nested"))
    File.write!(executable, "#!/bin/sh\nexit 0\n")
    File.chmod!(executable, 0o755)
    File.write!(Path.join(workspace, resource), "fixture")

    result_message =
      Jason.encode!(%{
        "method" => "item/completed",
        "params" => %{
          "item" => %{
            "type" => "agentMessage",
            "text" =>
              Jason.encode!(%{
                "schema" => "symphony.role-result/v1",
                "role" => "PLANNER",
                "outcome" => "plan_ready",
                "summary" => "verified",
                "evidence" => [],
                "findings" => []
              })
          }
        }
      })

    File.write!(codex_binary, """
    #!/bin/sh
    trace_file="${SYMP_TEST_CODEx_TRACE}"
    count=0
    while IFS= read -r line; do
      count=$((count + 1))
      printf 'JSON:%s\\n' "$line" >> "$trace_file"
      case "$count" in
        1) printf '%s\\n' '{"id":1,"result":{}}' ;;
        2) ;;
        3) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-capability"}}}' ;;
        4)
          printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-capability"}}}'
          printf '%s\\n' '#{result_message}'
          printf '%s\\n' '{"method":"turn/completed"}'
          ;;
      esac
    done
    """)

    File.chmod!(codex_binary, 0o755)

    previous_trace = System.get_env("SYMP_TEST_CODEx_TRACE")
    System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)

    on_exit(fn -> restore_env("SYMP_TEST_CODEx_TRACE", previous_trace) end)

    write_instance_config_file!(InstanceConfig.instance_config_file_path(),
      workspace_root: test_root,
      codex_command: "#{codex_binary} app-server",
      environment_capabilities: [
        %{
          "id" => "project-runtime",
          "command" => %{"executable" => ".venv/bin/python", "args" => ["--version"]},
          "resources" => [resource]
        }
      ]
    )

    issue = %Issue{
      id: "issue-capability-boundary",
      identifier: "CAP-BOUNDARY",
      title: "Capability boundary",
      description: "Deliver host facts",
      state: "In Progress",
      labels: ["symphony:role:planner"]
    }

    assert :ok = AgentRunner.run(issue, nil, role: :planner)

    payloads =
      trace_file
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.filter(&String.starts_with?(&1, "JSON:"))
      |> Enum.map(&String.trim_leading(&1, "JSON:"))
      |> Enum.map(&Jason.decode!/1)

    turn_payload = Enum.find(payloads, &(&1["method"] == "turn/start"))
    turn_text = get_in(turn_payload, ["params", "input", Access.at(0), "text"])

    assert get_in(turn_payload, ["params", "cwd"]) == workspace
    assert get_in(turn_payload, ["params", "sandboxPolicy", "type"]) == "readOnly"
    assert turn_text =~ "symphony.environment-capabilities/v1"
    assert turn_text =~ ".venv/bin/python"
    assert turn_text =~ resource
    refute turn_text =~ "--version"
    refute turn_text =~ "must-not-cross-prompt-boundary"
  end

  test "the shared prompt path exposes the report to every lifecycle role" do
    report = %{
      "schema" => "symphony.environment-capabilities/v1",
      "status" => "verified",
      "workspace" => "/tmp/workspace",
      "configuration_digest" => "digest",
      "verified_at" => "2026-09-19T00:00:00Z",
      "capabilities" => [%{"id" => "runtime", "status" => "verified"}]
    }

    issue = %Issue{
      id: "issue-all-roles",
      identifier: "CAP-ROLES",
      title: "All role report delivery",
      description: "Every role uses the shared prompt context"
    }

    for role <- [:pm, :planner, :reviewer, :implementer, :adversary, :archivist] do
      prompt = PromptBuilder.build_prompt(issue, role, %{environment_capabilities: report})
      assert prompt =~ "Host-verified environment capabilities (current dispatch):"
      assert prompt =~ "symphony.environment-capabilities/v1"
      assert prompt =~ "runtime"
    end
  end

  defp temporary_workspace(label) do
    Path.join(System.tmp_dir!(), "symphony-capabilities-#{label}-#{System.unique_integer([:positive])}")
  end
end
