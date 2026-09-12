defmodule SymphonyElixir.RoleRuntimePolicy do
  @moduledoc """
  Host-owned execution authority for one canonical SYMPHONY role.

  `RoleProfiles` supplies the semantic role metadata. This module is the binding
  layer that converts that metadata into the only Codex sandbox policy that a
  lifecycle role may receive. Instance configuration is intentionally not read
  here: it may provide mechanical settings, but it cannot widen role authority.
  """

  alias SymphonyElixir.RoleProfiles

  @type t :: %{
          role: RoleProfiles.role(),
          write_authority: RoleProfiles.write_authority(),
          thread_policy: RoleProfiles.thread_policy(),
          thread_sandbox: String.t(),
          turn_sandbox_policy: map(),
          network_access: false,
          model_tracker_tools: :disabled,
          git_metadata_protection: :not_required | :required
        }

  @read_only_sandbox "read-only"
  @workspace_write_sandbox "workspace-write"

  @spec for_role(RoleProfiles.role(), Path.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def for_role(role, workspace, opts \\ []) do
    with {:ok, profile} <- RoleProfiles.profile(role),
         :ok <- validate_workspace(workspace, opts) do
      {:ok, build_policy(role, profile, workspace)}
    end
  end

  @doc "Returns a bounded diagnostic projection safe to place in runtime metadata."
  @spec snapshot(t()) :: map()
  def snapshot(policy) when is_map(policy) do
    %{
      role: policy.role,
      write_authority: policy.write_authority,
      thread_policy: policy.thread_policy,
      sandbox_mode: policy.turn_sandbox_policy["type"],
      network_enabled: policy.network_access,
      model_tracker_tools: policy.model_tracker_tools,
      git_metadata_protection: policy.git_metadata_protection
    }
  end

  @doc false
  @spec validate(RoleProfiles.role(), t(), Path.t()) :: :ok | {:error, term()}
  def validate(role, policy, workspace) when is_map(policy) do
    case for_role(role, workspace) do
      {:ok, ^policy} -> :ok
      {:ok, _expected} -> {:error, :role_runtime_policy_tampered}
      {:error, reason} -> {:error, reason}
    end
  end

  def validate(_role, _policy, _workspace), do: {:error, :invalid_role_runtime_policy}

  defp build_policy(role, profile, workspace) do
    case profile.write_authority do
      :read_only ->
        %{
          role: role,
          write_authority: :read_only,
          thread_policy: profile.thread_policy,
          thread_sandbox: @read_only_sandbox,
          turn_sandbox_policy: %{
            "type" => "readOnly",
            "networkAccess" => false
          },
          network_access: false,
          model_tracker_tools: :disabled,
          git_metadata_protection: :not_required
        }

      :project_write ->
        %{
          role: role,
          write_authority: :project_write,
          thread_policy: profile.thread_policy,
          thread_sandbox: @workspace_write_sandbox,
          turn_sandbox_policy: %{
            "type" => "workspaceWrite",
            "writableRoots" => [workspace],
            "networkAccess" => false
          },
          network_access: false,
          model_tracker_tools: :disabled,
          git_metadata_protection: :required
        }
    end
  end

  defp validate_workspace(workspace, _opts) when is_binary(workspace) do
    if String.trim(workspace) == "" or String.contains?(workspace, ["\n", "\r", <<0>>]) do
      {:error, {:role_runtime_policy, :invalid_workspace}}
    else
      :ok
    end
  end

  defp validate_workspace(_workspace, _opts), do: {:error, {:role_runtime_policy, :invalid_workspace}}
end
