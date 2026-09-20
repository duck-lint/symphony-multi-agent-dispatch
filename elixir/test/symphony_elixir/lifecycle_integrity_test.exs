defmodule SymphonyElixir.LifecycleIntegrityTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.LifecycleIntegrity

  test "a changed or unsigned lifecycle event is not authoritative" do
    event = %{"schema" => "symphony.lifecycle/v1", "kind" => "lifecycle_started", "lifecycle_id" => "life"}
    signed = LifecycleIntegrity.sign(event, "host-secret")

    assert :ok = LifecycleIntegrity.verify(signed, "host-secret")

    assert {:error, :invalid_lifecycle_integrity} =
             LifecycleIntegrity.verify(Map.put(signed, "lifecycle_id", "forged"), "host-secret")

    assert {:error, :invalid_lifecycle_integrity} = LifecycleIntegrity.verify(event, "host-secret")
    assert {:error, :lifecycle_integrity_unavailable} = LifecycleIntegrity.verify(signed, nil)
  end

  test "fails closed without a signing secret and verifies event collections" do
    event = %{"schema" => "symphony.lifecycle/v1", "kind" => "lifecycle_started", "lifecycle_id" => "life"}

    assert ^event = LifecycleIntegrity.sign(event, nil)
    assert {:error, :invalid_lifecycle_integrity} = LifecycleIntegrity.verify(event)

    assert {:error, {:untrusted_lifecycle_event, :invalid_lifecycle_integrity}} =
             LifecycleIntegrity.verify_events([event], "host-secret")

    assert {:error, {:untrusted_lifecycle_event, :lifecycle_integrity_unavailable}} =
             LifecycleIntegrity.verify_events([event], nil)
  end

  test "returns no secret when the instance configuration cannot be loaded" do
    existing_path = InstanceConfig.instance_config_file_path()
    missing_path = Path.join(Path.dirname(existing_path), "missing-integrity-config.yml")
    store_pid = Process.whereis(InstanceConfigStore)

    if store_pid, do: Supervisor.terminate_child(SymphonyElixir.Supervisor, InstanceConfigStore)

    try do
      InstanceConfig.set_instance_config_file_path(missing_path)
      assert LifecycleIntegrity.configured_secret() == nil
    after
      InstanceConfig.set_instance_config_file_path(existing_path)
      if store_pid, do: Supervisor.restart_child(SymphonyElixir.Supervisor, InstanceConfigStore)
    end
  end
end
