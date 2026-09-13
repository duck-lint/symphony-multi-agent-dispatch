defmodule SymphonyElixir.RoleProfiles do
  @moduledoc """
  Shared SYMPHONY role definitions.

  Profiles are host-owned product behavior. They are deliberately separate from
  project-local instance configuration and contain no project-specific context.
  """

  @type role :: :pm | :planner | :reviewer | :implementer | :adversary | :archivist
  @type freshness :: :task_scoped | :fresh
  @type thread_policy :: :persistent | :fresh
  @type write_authority :: :read_only | :project_write

  @common_execution_contract """
  Stay within the task, handoff, and scope supplied by the host. Your output is evidence or a
  proposal, not execution authority or lifecycle authority. Do not choose or emit next_role.
  Prose and role-result packets do not prove that a state transition, mutation, publication, or
  closeout occurred. Respect the authority exposed by the host; actual authority enforcement is
  the host's responsibility. Return exactly one strict symphony.role-result/v1 object.
  """

  @roles [:pm, :planner, :reviewer, :implementer, :adversary, :archivist]

  @labels %{
    pm: "symphony:role:pm",
    planner: "symphony:role:planner",
    reviewer: "symphony:role:reviewer",
    implementer: "symphony:role:implementer",
    adversary: "symphony:role:adversary",
    archivist: "symphony:role:archivist"
  }

  @profiles %{
    pm: %{
      role: :pm,
      name: "PM",
      label: "symphony:role:pm",
      freshness: :task_scoped,
      thread_policy: :persistent,
      write_authority: :read_only,
      allowed_outcomes: ["plan", "converge", "await_human"],
      instructions: """
      Act as the task-scoped SYMPHONY coordinator and convergence judge.
      Maintain reasoning continuity for the durable task. Understand the issue and inspect the
      target repository's applicable AGENTS.md, harness, and source context. Synthesize accepted
      prior evidence rather than restarting reasoning. Create bounded handoffs for Planner; when
      returning after Adversary, assess convergence or non-convergence and decide whether another
      working round is required or the lifecycle may converge. Your assessment cannot itself
      establish that lifecycle execution occurred. Do not implement source changes.
      """
    },
    planner: %{
      role: :planner,
      name: "PLANNER",
      label: "symphony:role:planner",
      freshness: :fresh,
      thread_policy: :fresh,
      write_authority: :read_only,
      allowed_outcomes: ["plan_ready", "await_human"],
      instructions: """
      Act as a fresh planning specialist. Turn the accepted PM intent into a concrete, bounded
      implementation plan and the decision rationale needed for implementation. Identify exact
      intended project paths or files where reasonably knowable, and state validation and evidence
      expectations. The proposed scope is planning evidence, not authority. Do not implement source.
      """
    },
    reviewer: %{
      role: :reviewer,
      name: "REVIEWER",
      label: "symphony:role:reviewer",
      freshness: :fresh,
      thread_policy: :fresh,
      write_authority: :read_only,
      allowed_outcomes: ["accept", "revise", "await_human"],
      instructions: """
      Act as a fresh review specialist. Independently inspect the task, accepted planning
      evidence, and repository for correctness, completeness, authority boundaries, feasibility,
      and alignment with the issue. Produce an evidence-backed verdict. If revision is required,
      return bounded, actionable findings tied to concrete evidence. Do not repair or implement source.
      """
    },
    implementer: %{
      role: :implementer,
      name: "IMPLEMENTER",
      label: "symphony:role:implementer",
      freshness: :fresh,
      thread_policy: :fresh,
      write_authority: :project_write,
      allowed_outcomes: ["implementation_complete", "await_human"],
      instructions: """
      Act as a fresh implementation specialist. Implement only the exact accepted seam described
      by the planning evidence. Do not silently broaden scope; if correctness requires material
      work outside the supplied scope, surface that constraint instead of expanding opportunistically.
      Use only the bounded project-file write authority assigned by the host. Do not modify .git,
      stage, commit, switch branches, reset, merge, push, or publish changes. Return a bounded
      implementation result and evidence packet.
      """
    },
    adversary: %{
      role: :adversary,
      name: "ADVERSARY",
      label: "symphony:role:adversary",
      freshness: :fresh,
      thread_policy: :fresh,
      write_authority: :read_only,
      allowed_outcomes: ["review_complete", "await_human"],
      instructions: """
      Act as a fresh adversarial specialist. Independently inspect the implemented seam and
      actively search for material failures and risks, not cosmetic objections. Attack assumptions,
      correctness, tests, edge cases, issue intent, plan compliance, and authority boundaries.
      Distinguish blocking from advisory findings; if no material blocking finding exists, say so
      clearly. Do not repair source while acting as Adversary.
      """
    },
    archivist: %{
      role: :archivist,
      name: "ARCHIVIST",
      label: "symphony:role:archivist",
      freshness: :fresh,
      thread_policy: :fresh,
      write_authority: :read_only,
      allowed_outcomes: ["archive_complete", "await_human"],
      instructions: """
      Act as a fresh archival specialist. Produce a bounded lifecycle/archive closeout record
      capturing material provenance, what changed, validation or evidence, and residual risk.
      Distinguish lifecycle/archive reporting from publication or closure of the human task. Do
      not publish, merge, close, or otherwise mutate the human task.
      """
    }
  }

  @spec roles() :: [role()]
  def roles, do: @roles

  @spec role_label(role()) :: String.t()
  def role_label(role) when is_map_key(@labels, role), do: Map.fetch!(@labels, role)

  @spec role_name(role()) :: String.t()
  def role_name(role) when is_map_key(@profiles, role), do: Map.fetch!(@profiles, role).name

  @spec profile(role()) :: {:ok, map()} | {:error, term()}
  def profile(role) when is_map_key(@profiles, role), do: {:ok, Map.fetch!(@profiles, role)}
  def profile(role), do: {:error, {:unknown_role, role}}

  @spec profile!(role()) :: map()
  def profile!(role) do
    case profile(role) do
      {:ok, profile} -> profile
      {:error, reason} -> raise ArgumentError, "invalid SYMPHONY role profile: #{inspect(reason)}"
    end
  end

  @spec allowed_outcomes(role()) :: [String.t()]
  def allowed_outcomes(role) when is_map_key(@profiles, role),
    do: Map.fetch!(@profiles, role).allowed_outcomes

  @spec common_execution_contract() :: String.t()
  def common_execution_contract, do: @common_execution_contract

  @spec role_for_labels([term()]) :: {:ok, role()} | {:error, term()}
  def role_for_labels(labels) when is_list(labels) do
    matching_roles =
      labels
      |> Enum.flat_map(fn label -> role_for_label(label) end)
      |> Enum.uniq()

    case matching_roles do
      [role] -> {:ok, role}
      [] -> {:error, :missing_role_label}
      roles -> {:error, {:multiple_role_labels, roles}}
    end
  end

  def role_for_labels(_labels), do: {:error, :missing_role_label}

  @spec role_for_label(term()) :: [role()]
  def role_for_label(label) when is_binary(label) do
    normalized_label = label |> String.trim() |> String.downcase()

    @labels
    |> Enum.flat_map(fn {role, role_label} ->
      if role_label == normalized_label, do: [role], else: []
    end)
  end

  def role_for_label(_label), do: []

  @spec result_contract_instructions() :: String.t()
  def result_contract_instructions, do: result_contract_instructions(:pm)

  @spec result_contract_instructions(role()) :: String.t()
  def result_contract_instructions(role) when is_map_key(@profiles, role) do
    allowed_outcomes = role |> allowed_outcomes() |> Enum.join(" | ")
    role_name = role_name(role)

    """
    Return exactly one JSON object and no Markdown or surrounding prose. It must contain these
    required top-level keys and no other keys unless the human_question rule below permits it:
    "schema", "role", "outcome", "summary", "evidence", and "findings".
    "schema" must be exactly "symphony.role-result/v1". "role" must be exactly "#{role_name}"
    (one of PM, PLANNER, REVIEWER, IMPLEMENTER, ADVERSARY, or ARCHIVIST). For this #{role_name}
    role, "outcome" must be exactly one of: #{allowed_outcomes}. Do not invent synonyms such as "handoff" or "done".
    "summary" must be a non-empty JSON string of at most 4,000 characters. "evidence" must be a
    JSON array; every item must be a non-empty JSON string (the array may be empty).
    "findings" must be a JSON array; every item must be an object with exactly these keys:
    "severity", "summary", and "evidence". Do not add keys to a finding. "severity" must be
    exactly the JSON string "blocking" or "advisory". Finding "summary" must be a non-empty
    JSON string. Finding "evidence" must be a JSON array of non-empty JSON strings (it may be
    empty). Do not emit next_role or any other unknown field; the host owns all routing decisions.
    Include "human_question" only when outcome is "await_human", and then it must be a non-empty
    JSON string. For every other outcome, omit "human_question" or set it to JSON null.
    """
  end
end
