defmodule SymphonyElixir.PromptBuilder do
  @moduledoc """
  Builds a role-specific SYMPHONY prompt from host-selected profile and issue context.

  Role selection is an input from the host. This module does not inspect issue labels
  and does not read project-local instance configuration for prompt content.
  """

  alias SymphonyElixir.RoleProfiles
  alias SymphonyElixir.Tracker.Issue

  @spec build_prompt(Issue.t(), RoleProfiles.role(), map()) :: String.t()
  def build_prompt(%Issue{} = issue, role, context \\ %{}) when is_map(context) do
    profile = profile_for(role, Map.get(context, :role_profile) || RoleProfiles.profile!(role))
    handoff = Map.get(context, :handoff)

    """
    You are executing the SYMPHONY role #{profile.name}.

    Common execution contract:
    #{String.trim(RoleProfiles.common_execution_contract())}

    Role instructions:
    #{String.trim(profile.instructions)}

    #{RoleProfiles.result_contract_instructions()}

    Host-supplied handoff/context:
    #{format_context(handoff)}

    Issue context:
    Identifier: #{issue.identifier || "(missing)"}
    Title: #{issue.title || "(missing)"}
    State: #{issue.state || "(missing)"}
    URL: #{issue.url || "(missing)"}
    Body:
    #{issue.description || "No description provided."}
    """
    |> String.trim()
  end

  defp format_context(nil), do: "No additional handoff was supplied."
  defp format_context(context) when is_binary(context), do: context
  defp format_context(context), do: inspect(context, pretty: true)

  defp profile_for(role, %{role: role} = profile), do: profile

  defp profile_for(role, profile) when is_map(profile) do
    raise ArgumentError,
          "role profile #{inspect(profile[:role])} does not match host-selected role #{inspect(role)}"
  end
end
