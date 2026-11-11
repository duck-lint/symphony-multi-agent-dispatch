defmodule SymphonyElixir.DiagnosticCLI do
  @moduledoc """
  Operator-only project commissioning through production workspace mechanisms.

  No OTP runtime, orchestrator, tracker issue, lifecycle ledger, Codex agent,
  or PM-thread state is started or consulted by these commands.
  """

  alias SymphonyElixir.{Config, InstanceConfig, RoleProfiles, RoleRuntimePolicy, Workspace, WorkspacePreparation}

  @acknowledgement_switch :i_understand_that_this_will_be_running_without_the_usual_guardrails
  @switches [
    {@acknowledgement_switch, :boolean},
    help: :boolean,
    config: :string,
    run: :string,
    role: :string,
    worker: :string
  ]

  @usage """
  Usage:
    symphony lab check [--config <instance_config.yml>]
    symphony lab provision --run <name> [--worker <host>] [--config <path>] --i-understand-that-this-will-be-running-without-the-usual-guardrails
    symphony lab verify --run <name> --role <pm|planner|reviewer|implementer|adversary|archivist> [--worker <host>] [--config <path>] --i-understand-that-this-will-be-running-without-the-usual-guardrails
    symphony lab destroy --run <name> [--worker <host>] [--config <path>] --i-understand-that-this-will-be-running-without-the-usual-guardrails

  Diagnostics do not dispatch agents or write GitHub lifecycle state.
  Run names are 1-64 ASCII letters, digits, hyphens, or underscores, starting with a letter or digit.
  Workspace hooks may execute side effects outside the diagnostic workspace.
  """

  @spec evaluate([String.t()]) :: {:ok, String.t()} | {:help, String.t()} | {:error, String.t()}
  def evaluate(args) do
    case OptionParser.parse(args, strict: @switches, aliases: [h: :help]) do
      {opts, commands, []} ->
        if Keyword.get(opts, :help, false) do
          {:help, @usage}
        else
          case commands do
            [command] when command in ["check", "provision", "verify", "destroy"] ->
              evaluate_command(command, opts)

            _ ->
              {:error, @usage}
          end
        end

      _ ->
        {:error, @usage}
    end
  end

  defp evaluate_command(command, opts) do
    with :ok <- validate_options(command, opts),
         :ok <- require_acknowledgement(command, opts),
         {:ok, path} <- select_config_path(opts),
         {:ok, settings} <- load_settings(path),
         {:ok, worker_host} <- select_worker(command, opts, settings) do
      dispatch(command, opts, path, worker_host)
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp validate_options("check", opts) do
    if Enum.any?([:run, :role, :worker], &Keyword.has_key?(opts, &1)) do
      {:error, "check accepts only --config"}
    else
      :ok
    end
  end

  defp validate_options(command, opts) do
    cond do
      not is_binary(Keyword.get(opts, :run)) or String.trim(Keyword.get(opts, :run)) == "" ->
        {:error, "#{command} requires --run <name>"}

      command != "verify" and Keyword.has_key?(opts, :role) ->
        {:error, "--role is only available for verify"}

      command == "verify" and not is_binary(Keyword.get(opts, :role)) ->
        {:error, "verify requires --role"}

      true ->
        :ok
    end
  end

  defp require_acknowledgement("check", _opts), do: :ok

  defp require_acknowledgement(_command, opts) do
    if Keyword.get(opts, @acknowledgement_switch, false) do
      :ok
    else
      {:error, "Diagnostic hooks and cleanup have real side effects. Pass --i-understand-that-this-will-be-running-without-the-usual-guardrails"}
    end
  end

  defp select_config_path(opts) do
    path = Keyword.get(opts, :config, Path.join(".symphony", "instance_config.yml"))

    if is_binary(path) and String.trim(path) != "" do
      expanded = Path.expand(path)
      if File.regular?(expanded), do: {:ok, expanded}, else: {:error, "instance_config file not found: #{expanded}"}
    else
      {:error, "invalid instance config path"}
    end
  end

  defp load_settings(path) do
    :ok = InstanceConfig.set_instance_config_file_path(path)
    Config.settings()
  end

  defp select_worker("check", _opts, _settings), do: {:ok, nil}

  defp select_worker(_command, opts, settings) do
    configured =
      settings.worker.ssh_hosts
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case {Keyword.get(opts, :worker), configured} do
      {nil, []} -> {:ok, nil}
      {nil, [host]} -> {:ok, host}
      {nil, _hosts} -> {:error, "multiple SSH workers configured; specify --worker <host>"}
      {host, hosts} when is_binary(host) ->
        if host in hosts, do: {:ok, host}, else: {:error, "worker is not listed in the selected instance configuration"}
    end
  end

  defp dispatch("check", _opts, path, _worker_host) do
    {:ok, encode(%{status: "configuration_valid", config: path, scope: "schema_and_tracker_settings_only"})}
  end

  defp dispatch("provision", opts, path, worker_host) do
    name = Keyword.fetch!(opts, :run)

    case Workspace.create_for_diagnostic(name, worker_host) do
      {:ok, workspace} ->
        {:ok, encode(%{status: "provisioned", config: path, run: name, workspace: workspace, worker_host: worker_host, note: "after_create executed if configured; role preparation has not been verified"})}

      {:error, reason} ->
        {:error, "diagnostic provisioning failed: #{inspect(reason)}"}
    end
  end

  defp dispatch("verify", opts, path, worker_host) do
    name = Keyword.fetch!(opts, :run)

    with {:ok, role} <- parse_role(Keyword.fetch!(opts, :role)),
         {:ok, workspace} <- Workspace.existing_diagnostic_workspace(name, worker_host),
         {:ok, result} <- WorkspacePreparation.with_prepared(workspace, role, "diagnostic-" <> name, worker_host, fn prepared ->
           {:ok,
            %{
              status: "prepared",
              config: path,
              run: name,
              workspace: workspace,
              worker_host: worker_host,
              role: RoleProfiles.role_name(role),
              runtime_authority: RoleRuntimePolicy.snapshot(prepared.role_policy),
              workspace_boundary: prepared.boundary,
              source_provenance: prepared.source_provenance,
              environment_capabilities: prepared.environment_capabilities,
              note: "Checks ran under host authority; no Codex agent was launched. after_run hook runs after verification."
            }}
         end) do
      {:ok, encode(result)}
    else
      {:error, reason} -> {:error, "diagnostic verification failed: #{inspect(reason)}"}
    end
  end

  defp dispatch("destroy", opts, path, worker_host) do
    name = Keyword.fetch!(opts, :run)

    case Workspace.remove_diagnostic(name, worker_host) do
      {:ok, _removed} ->
        {:ok, encode(%{status: "removed", config: path, run: name, worker_host: worker_host})}

      {:error, reason} ->
        {:error, "diagnostic cleanup failed: #{inspect(reason)}"}
    end
  end

  defp parse_role(value) do
    role = Enum.find(RoleProfiles.roles(), &(Atom.to_string(&1) == String.downcase(value)))

    case role do
      nil -> {:error, {:unknown_role, value}}
      role -> {:ok, role}
    end
  end

  defp encode(result), do: Jason.encode!(result, pretty: true)
end
