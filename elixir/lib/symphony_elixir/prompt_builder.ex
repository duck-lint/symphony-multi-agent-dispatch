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
    correction_feedback = Map.get(context, :correction_feedback)

    """
    You are executing the SYMPHONY role #{profile.name}.

    Role instructions:
    #{String.trim(profile.instructions)}

    #{optional_context_section("Host-enforced runtime authority", runtime_authority)}
    #{optional_context_section("Host-derived lifecycle context", lifecycle_context)}
    #{reconciliation_section(handoff)}
    #{revision_reconciliation_section(role, handoff)}
    #{optional_context_section("Host correction diagnostic (the prior result was not committed; correct the result contract only)", correction_feedback)}
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

  # Structured lifecycle evidence must remain complete at the prompt boundary.
  # Jason is also the repository's durable lifecycle-ledger encoding, so this
  # keeps prompt evidence in the same explicit, machine-readable representation
  # without changing which events or fields the coordinator selected.
  defp format_context(context), do: Jason.encode!(context, pretty: true)

  defp handoff_reconciliation(%{reconciliation: reconciliation}), do: reconciliation
  defp handoff_reconciliation(_handoff), do: nil

  defp optional_context_section(_label, nil), do: ""

  defp optional_context_section(label, context),
    do: "\n#{label}:\n#{format_context(context)}\n"

  defp reconciliation_section(handoff) do
    case handoff_reconciliation(handoff) do
      nil ->
        ""

      reconciliation ->
        optional_context_section(
          "Host-projected evidence reconciliation (accepted event data; not a semantic verdict)",
          reconciliation
        )
    end
  end

  defp revision_reconciliation_section(:planner, %{revision_reconciliation: projection})
       when is_map(projection) do
    """

    Planner revision reconciliation (host-required evidence accounting; not a semantic verdict):
    #{format_context(projection)}

    For this revised planning attempt:
    - Serialize a "revision_reconciliation" object with exactly "rejected_planner_transition_id",
      "reviewer_transition_id", and "finding_responses"; copy both transition IDs from the projection.
    - Include one finding response for every projected finding, in displayed order, with exactly
      "finding_ref", "assessment", and "plan_excerpt"; copy each deterministic finding reference exactly once.
    - For "plan_ready", use an exact excerpt from the resulting plan text in "summary" for each response.
      For "await_human" or "non_converged", set each "plan_excerpt" to JSON null.
    - Compare the rejected plan against every Reviewer finding and its supporting evidence.
    - State what the original plan did and did not establish.
    - Assess each finding as a genuine defect, an already-satisfied requirement, an authority conflict, or an unresolved question.
    - Incorporate warranted corrections while retaining valid portions of the original plan.
    - Account for every finding individually, including evidence-supported disagreement.
    - For each finding, identify the corresponding correction in the revised plan with concrete verification obligations and execution ownership where applicable. Do not require yourself to execute verification owned by the Implementer.
    - Acknowledging or paraphrasing a finding is not a correction. The host checks references and exact excerpts; the Reviewer judges semantic adequacy.
    """
  end

  defp revision_reconciliation_section(_role, _handoff), do: ""

  defp profile_for(role, %{role: role} = profile), do: profile

  defp profile_for(role, profile) when is_map(profile) do
    raise ArgumentError,
          "role profile #{inspect(profile[:role])} does not match host-selected role #{inspect(role)}"
  end
end
