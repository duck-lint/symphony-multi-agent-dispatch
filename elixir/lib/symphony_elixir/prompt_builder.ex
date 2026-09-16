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
    runtime_authority = Map.get(context, :runtime_authority)
    lifecycle_context = Map.get(context, :lifecycle_context)

    runtime_authority_section =
      case runtime_authority do
        nil -> ""
        authority -> "\nHost-enforced runtime authority:\n#{format_context(authority)}\n"
      end

    lifecycle_context_section =
      case lifecycle_context do
        nil -> ""
        context -> "\nHost-derived lifecycle context:\n#{format_context(context)}\n"
      end

    """
    You are executing the SYMPHONY role #{profile.name}.

    Role instructions:
    #{String.trim(profile.instructions)}

    #{runtime_authority_section}
    #{lifecycle_context_section}
    #{RoleProfiles.result_contract_instructions(profile.role)}

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
