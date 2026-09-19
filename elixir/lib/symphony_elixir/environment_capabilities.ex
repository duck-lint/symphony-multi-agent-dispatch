defmodule SymphonyElixir.EnvironmentCapabilities do
  @moduledoc """
  Verifies project-declared environment capabilities for one role dispatch.

  The declaration is configuration input; this module produces the only
  specialist-facing evidence. It deliberately omits command arguments and
  command output so configuration secrets and diagnostic output do not cross
  the prompt boundary.
  """

  alias SymphonyElixir.{Config, Workspace}

  @schema "symphony.environment-capabilities/v1"

  @type worker_host :: String.t() | nil

  @spec verify(String.t(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def verify(workspace, worker_host \\ nil) when is_binary(workspace) do
    capabilities = Config.settings!().environment.capabilities
    declarations = Enum.map(capabilities, &declaration_for_digest/1)
    results = Enum.map(capabilities, &verify_capability(&1, workspace, worker_host))
    status = overall_status(results)

    report = %{
      "schema" => @schema,
      "status" => status,
      "workspace" => Path.expand(workspace),
      "configuration_digest" => digest(declarations),
      "verified_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "capabilities" => results
    }

    case report["status"] do
      status when status in ["verified", "not_checked"] ->
        {:ok, report}

      _status ->
        {:error, {:environment_capability_verification_failed, report}}
    end
  end

  defp overall_status([]), do: "not_checked"

  defp overall_status(results) do
    if Enum.all?(results, &(&1["status"] == "verified")), do: "verified", else: "failed"
  end

  defp verify_capability(capability, workspace, worker_host) do
    base = declaration(capability)

    case verify_resources(capability.resources, workspace, worker_host) do
      :ok ->
        case verify_command(capability.command, capability.working_directory, workspace, worker_host) do
          :ok -> Map.put(base, "status", "verified")
          {:error, reason} -> failed_result(base, reason)
        end

      {:error, reason} ->
        failed_result(base, reason)
    end
  end

  defp verify_resources([], _workspace, _worker_host), do: :ok

  defp verify_resources(resources, workspace, worker_host) do
    Enum.reduce_while(resources, :ok, fn resource, :ok ->
      case Workspace.workspace_resource_available?(workspace, resource, worker_host) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:resource, resource, reason}}}
      end
    end)
  end

  defp verify_command(nil, _working_directory, _workspace, _worker_host), do: :ok

  defp verify_command(command, working_directory, workspace, worker_host) do
    Workspace.run_verification_command(workspace, working_directory, command, worker_host)
  end

  defp failed_result(base, {:resource, resource, :unavailable}) do
    base
    |> Map.put("status", "unavailable")
    |> Map.put("observed", %{"resource" => resource, "available" => false})
  end

  defp failed_result(base, {:resource, resource, _reason}) do
    base
    |> Map.put("status", "failed")
    |> Map.put("observed", %{"resource" => resource, "error" => "verification_error"})
  end

  defp failed_result(base, {:failed, status}) do
    base
    |> Map.put("status", "failed")
    |> Map.put("observed", %{"command_executed" => true, "exit_status" => status})
  end

  defp failed_result(base, :unavailable) do
    base
    |> Map.put("status", "unavailable")
    |> Map.put("observed", %{"command_executed" => false})
  end

  defp failed_result(base, {:timeout, timeout_ms}) do
    base
    |> Map.put("status", "failed")
    |> Map.put("observed", %{"command_executed" => true, "timeout_ms" => timeout_ms})
  end

  defp failed_result(base, _reason) do
    base
    |> Map.put("status", "failed")
    |> Map.put("observed", %{"error" => "verification_error"})
  end

  defp declaration(capability) do
    command =
      case capability.command do
        nil ->
          nil

        %{"executable" => executable, "args" => args} ->
          %{
            "executable" => executable,
            "arguments_digest" => digest(args)
          }

        %{"executable" => executable} ->
          %{"executable" => executable, "arguments_digest" => digest([])}
      end

    %{
      "id" => capability.id,
      "working_directory" => capability.working_directory,
      "resources" => capability.resources,
      "command" => command
    }
  end

  defp declaration_for_digest(%{id: id, command: command, resources: resources, working_directory: working_directory}) do
    %{
      "id" => id,
      "command" => command,
      "resources" => resources,
      "working_directory" => working_directory
    }
  end

  defp digest(value) do
    data = :erlang.term_to_binary(value, [:deterministic])
    Base.encode16(:crypto.hash(:sha256, data), case: :lower)
  end
end
