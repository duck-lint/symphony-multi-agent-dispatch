defmodule SymphonyElixir.DiagnosticCLITest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.DiagnosticCLI

  @ack_flag "--i-understand-that-this-will-be-running-without-the-usual-guardrails"

  test "configuration check does not require a dangerous-operation acknowledgement" do
    path = InstanceConfig.instance_config_file_path()

    assert {:ok, json} = DiagnosticCLI.evaluate(["check", "--config", path])
    assert %{"status" => "configuration_valid", "scope" => "schema_and_tracker_settings_only"} =
             Jason.decode!(json)

    assert {:error, message} = DiagnosticCLI.evaluate(["check", "--run", "unwanted"])
    assert message =~ "check accepts only --config"
  end

  test "provision, prepare and remove a diagnostic without affecting issue workspaces" do
    path = InstanceConfig.instance_config_file_path()
    root = Path.join(Path.dirname(path), "workspaces")

    write_instance_config_file!(path,
      workspace_root: root,
      hook_after_create: "printf 'source' > seed.txt",
      hook_before_run: "printf 'ready' > ready.txt",
      hook_after_run: "printf 'finished' > after-run.txt",
      environment_capabilities: [
        %{"id" => "seed", "resources" => ["seed.txt", "ready.txt"]}
      ]
    )

    assert {:ok, issue_workspace} = Workspace.create_for_issue("ISSUE-900")
    assert File.exists?(Path.join(issue_workspace, "seed.txt"))
    assert {:error, :reserved_diagnostic_workspace_namespace} =
             Workspace.create_for_issue(".symphony-diagnostics")

    assert {:ok, provisioned} =
             DiagnosticCLI.evaluate(["provision", "--run", "first", "--config", path, @ack_flag])

    %{"workspace" => workspace, "status" => "provisioned"} = Jason.decode!(provisioned)
    assert workspace == Path.join([root, ".symphony-diagnostics", "first"])
    assert File.read!(Path.join(workspace, "seed.txt")) == "source"

    assert {:error, message} =
             DiagnosticCLI.evaluate(["provision", "--run", "first", "--config", path, @ack_flag])

    assert message =~ "diagnostic_workspace_already_exists"

    assert {:ok, verified} =
             DiagnosticCLI.evaluate([
               "verify",
               "--run",
               "first",
               "--role",
               "implementer",
               "--config",
               path,
               @ack_flag
             ])

    result = Jason.decode!(verified)
    assert result["status"] == "prepared"
    assert result["role"] == "IMPLEMENTER"
    assert result["runtime_authority"]["write_authority"] == "project_write"
    assert result["environment_capabilities"]["status"] == "verified"
    assert result["source_provenance"]["status"] == "not_checked"
    assert File.read!(Path.join(workspace, "after-run.txt")) == "finished"

    assert {:ok, removed} =
             DiagnosticCLI.evaluate(["destroy", "--run", "first", "--config", path, @ack_flag])

    assert Jason.decode!(removed)["status"] == "removed"
    refute File.exists?(workspace)
    assert File.exists?(Path.join(issue_workspace, "seed.txt"))

    assert {:error, message} =
             DiagnosticCLI.evaluate(["verify", "--run", "first", "--role", "planner", "--config", path, @ack_flag])

    assert message =~ "diagnostic_workspace_missing"
  end

  test "preparation failures remain visible and still invoke after_run" do
    path = InstanceConfig.instance_config_file_path()
    root = Path.join(Path.dirname(path), "workspaces")

    write_instance_config_file!(path,
      workspace_root: root,
      hook_before_run: "exit 7",
      hook_after_run: "touch after-failure.txt"
    )

    assert {:ok, _provisioned} =
             DiagnosticCLI.evaluate(["provision", "--run", "fail-check", "--config", path, @ack_flag])

    assert {:error, error} =
             DiagnosticCLI.evaluate([
               "verify",
               "--run",
               "fail-check",
               "--role",
               "planner",
               "--config",
               path,
               @ack_flag
             ])

    assert error =~ "workspace_hook_failed"
    workspace = Path.join([root, ".symphony-diagnostics", "fail-check"])
    assert File.exists?(Path.join(workspace, "after-failure.txt"))

    assert {:ok, _removed} =
             DiagnosticCLI.evaluate(["destroy", "--run", "fail-check", "--config", path, @ack_flag])
  end

  test "rejects missing acknowledgement, unsafe names, and unknown roles" do
    path = InstanceConfig.instance_config_file_path()

    assert {:error, message} =
             DiagnosticCLI.evaluate(["provision", "--run", "valid", "--config", path])

    assert message =~ "without-the-usual-guardrails"

    assert {:error, message} =
             DiagnosticCLI.evaluate(["provision", "--run", "../outside", "--config", path, @ack_flag])

    assert message =~ "invalid_diagnostic_workspace_name"

    assert {:error, message} =
             DiagnosticCLI.evaluate(["verify", "--run", "some-run", "--role", "not-a-role", "--config", path, @ack_flag])

    assert message =~ "unknown_role"
  end
end
