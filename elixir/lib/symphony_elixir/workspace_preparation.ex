defmodule SymphonyElixir.WorkspacePreparation do
  @moduledoc """
  Shared, role-bound preparation for production and diagnostic workspaces.

  This module prepares an already materialized workspace. It owns no issue
  intake, lifecycle transition, Codex thread, or durable state authority.
  """

  alias SymphonyElixir.{EnvironmentCapabilities, RoleRuntimePolicy, Workspace}

  @type worker_host :: String.t() | nil

  @spec with_prepared(
          Path.t(),
          atom(),
          map() | String.t(),
          worker_host(),
          (map() -> term())
        ) :: term()
  def with_prepared(workspace, role, context, worker_host, on_prepared)
      when is_binary(workspace) and is_function(on_prepared, 1) do
    with {:ok, role_policy} <- RoleRuntimePolicy.for_role(role, workspace, worker_host: worker_host),
         {:ok, boundary} <- Workspace.enforce_role_boundary(workspace, role_policy, worker_host) do
      try do
        with :ok <- Workspace.run_before_run_hook(workspace, context, worker_host),
             {:ok, source_provenance} <- Workspace.verify_source_provenance(workspace, worker_host),
             {:ok, environment_capabilities} <- EnvironmentCapabilities.verify(workspace, worker_host) do
          on_prepared.(%{
            workspace: workspace,
            worker_host: worker_host,
            role_policy: role_policy,
            boundary: boundary,
            source_provenance: source_provenance,
            environment_capabilities: environment_capabilities
          })
        end
      after
        Workspace.run_after_run_hook(workspace, context, worker_host)
      end
    end
  end
end
