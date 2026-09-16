defmodule SymphonyElixir.RoleKernelTest do
  use SymphonyElixir.TestSupport

  @roles [
    {:pm, "PM", "symphony:role:pm"},
    {:planner, "PLANNER", "symphony:role:planner"},
    {:reviewer, "REVIEWER", "symphony:role:reviewer"},
    {:implementer, "IMPLEMENTER", "symphony:role:implementer"},
    {:adversary, "ADVERSARY", "symphony:role:adversary"},
    {:archivist, "ARCHIVIST", "symphony:role:archivist"}
  ]

  test "role labels map exactly to canonical roles and ignore unrelated labels" do
    for {role, _name, label} <- @roles do
      assert {:ok, ^role} = RoleProfiles.role_for_labels(["unrelated", String.upcase(label)])
      assert {:ok, ^role} = RoleRouter.role_for_issue(%Issue{labels: [label]})
    end
  end

  test "zero or multiple lifecycle role labels are invalid" do
    assert {:error, :missing_role_label} = RoleProfiles.role_for_labels(["symphony:auto", "backend"])

    assert {:error, {:multiple_role_labels, roles}} =
             RoleProfiles.role_for_labels([
               "symphony:role:pm",
               "SYMPHONY:ROLE:PLANNER",
               "backend"
             ])

    assert Enum.sort(roles) == [:planner, :pm]
    assert {:error, :missing_role_label} = RoleRouter.role_for_issue(%Issue{labels: []})
    assert {:error, :missing_role_label} = RoleRouter.role_for_issue(:not_an_issue)
    assert {:error, :missing_role_label} = RoleRouter.profile_for_issue(:not_an_issue)
  end

  test "dispatch derives a profile only from a valid issue role label" do
    issue = %Issue{labels: ["symphony:role:planner", "backend"]}
    assert {:ok, %{role: :planner}} = Orchestrator.role_profile_for_dispatch_for_test(issue)

    assert {:error, :missing_role_label} =
             Orchestrator.role_profile_for_dispatch_for_test(%Issue{labels: []})

    assert {:error, {:multiple_role_labels, _roles}} =
             Orchestrator.role_profile_for_dispatch_for_test(%Issue{
               labels: ["symphony:role:pm", "symphony:role:planner"]
             })
  end

  test "role profile metadata defines freshness, thread, authority, and outcomes" do
    assert RoleProfiles.roles() == Enum.map(@roles, &elem(&1, 0))

    for {role, name, label} <- @roles do
      profile = RoleProfiles.profile!(role)
      assert profile.role == role
      assert profile.name == name
      assert profile.label == label
      assert is_binary(profile.instructions)
      assert is_list(profile.allowed_outcomes)
      assert RoleProfiles.role_label(role) == label
      assert RoleProfiles.role_name(role) == name
    end

    assert RoleProfiles.profile!(:pm).freshness == :task_scoped
    assert RoleProfiles.profile!(:pm).thread_policy == :persistent
    assert RoleProfiles.profile!(:pm).write_authority == :read_only
    assert RoleProfiles.profile!(:implementer).freshness == :fresh
    assert RoleProfiles.profile!(:implementer).thread_policy == :fresh
    assert RoleProfiles.profile!(:implementer).write_authority == :project_write
    assert {:error, {:unknown_role, :architect}} = RoleProfiles.profile(:architect)
    assert_raise ArgumentError, fn -> RoleProfiles.profile!(:architect) end
    assert RoleProfiles.role_for_label(:not_a_label) == []
    assert RoleProfiles.role_for_labels(:not_a_list) == {:error, :missing_role_label}
    assert RoleProfiles.result_contract_instructions() =~ "Do not emit next_role"
  end

  test "role prompts share the evidence contract and retain distinct behavior" do
    issue = %Issue{identifier: "T-1", title: "Profile reconciliation"}

    distinctive_behavior = %{
      pm: "project-manager companion for the coding harness",
      planner: "convert intent into an executable plan",
      reviewer: "judge whether a proposed plan satisfies the verification contract",
      implementer: "execute one clear seam at a time",
      adversary: "find the cheapest way the current plan",
      archivist: "keep repo-local memory accurate"
    }

    for role <- RoleProfiles.roles() do
      prompt = PromptBuilder.build_prompt(issue, role)

      assert prompt =~ "You are executing the SYMPHONY role #{RoleProfiles.role_name(role)}."
      assert prompt =~ "Return exactly one JSON object and no Markdown or surrounding prose."
      assert prompt =~ "\"outcome\" must be exactly one of:"
      assert prompt =~ "Do not invent synonyms such as \"handoff\" or \"done\"."
      assert prompt =~ "required top-level keys and no other keys"
      assert prompt =~ "role\" must be exactly \"#{RoleProfiles.role_name(role)}\""
      assert prompt =~ "summary\" must be a non-empty JSON string of at most 4,000 characters"
      assert prompt =~ "evidence\" must be a JSON array"
      assert prompt =~ "findings\" must be a JSON array"
      assert prompt =~ "exactly these keys:"
      assert prompt =~ "Finding \"evidence\" must be a JSON array of non-empty JSON strings"
      assert prompt =~ "Include \"human_question\" only when outcome is \"await_human\""
      assert prompt =~ "omit \"human_question\" or set it to JSON null"
      assert prompt =~ distinctive_behavior[role]
      refute prompt =~ "nickname_candidates"
      refute prompt =~ "already an actual subagent"
      refute prompt =~ "recursively launch"
      refute prompt =~ "harness/README.md"
      refute prompt =~ "recommended next agent"
      refute prompt =~ "admissibility-blocked"
      refute prompt =~ "Pilot"
    end

    prompt =
      PromptBuilder.build_prompt(issue, :pm, %{handoff: %{round: 2, findings: [:advisory]}})

    assert prompt =~ "round: 2"
    assert prompt =~ "findings: [:advisory]"

    implementer_prompt = PromptBuilder.build_prompt(issue, :implementer)
    assert implementer_prompt =~ "validate the result against live runtime"

    for role <- [:planner, :reviewer, :adversary, :archivist] do
      assert RoleProfiles.profile!(role).write_authority == :read_only
      assert RoleProfiles.profile!(role).freshness == :fresh
      assert RoleProfiles.profile!(role).thread_policy == :fresh
    end

    refute RoleProfiles.profile!(:planner).instructions =~ "You may edit project-local harness"
    refute RoleProfiles.profile!(:archivist).instructions =~ "You may edit"
    refute RoleProfiles.profile!(:implementer).instructions =~ "tracker or verification status"
    refute RoleProfiles.profile!(:reviewer).instructions =~ "implementation satisfies the plan"
  end

  test "legal lifecycle transitions are host-owned" do
    assert Lifecycle.transition(:pm, :plan, %{pm_phase: :initial}) == {:ok, :planner}
    assert Lifecycle.transition(:pm, "plan", %{pm_phase: :returning}) == {:ok, :planner}

    assert Lifecycle.transition(:planner, "plan_ready") == {:ok, :reviewer}
    assert Lifecycle.transition(:reviewer, "revise") == {:ok, :planner}
    assert Lifecycle.transition(:reviewer, "accept", %{findings: []}) == {:ok, :implementer}
    assert Lifecycle.transition(:implementer, "implementation_complete") == {:ok, :adversary}
    assert Lifecycle.transition(:adversary, "review_complete") == {:ok, :pm}

    returning_context = %{
      pm_phase: :returning,
      completed_working_round?: true,
      preceding_adversary_findings: []
    }

    assert Lifecycle.transition(:pm, "converge", returning_context) == {:ok, :archivist}
    assert Lifecycle.transition(:archivist, "archive_complete") == {:ok, :lifecycle_complete}

    for role <- RoleProfiles.roles() do
      assert Lifecycle.transition(role, "await_human") == {:ok, :await_human}
    end
  end

  test "illegal lifecycle transitions and initial PM convergence are rejected" do
    assert Lifecycle.transition(:pm, "converge", %{pm_phase: :initial}) ==
             {:error, :initial_pm_cannot_converge}

    assert Lifecycle.transition(:pm, "converge", %{pm_phase: :returning}) ==
             {:error, :pm_convergence_precondition_not_met}

    assert Lifecycle.transition(:pm, "converge", %{
             pm_phase: :returning,
             completed_working_round?: true,
             preceding_adversary_findings: [%{"severity" => "blocking"}]
           }) == {:error, :blocking_adversary_findings}

    assert Lifecycle.transition(:pm, "plan", %{pm_phase: :unexpected}) ==
             {:error, {:invalid_pm_phase, :unexpected}}

    assert Lifecycle.transition(:reviewer, "accept", %{
             findings: [%{"severity" => "blocking"}]
           }) == {:error, :reviewer_accept_has_blocking_findings}

    assert Lifecycle.transition(:archivist, "plan_ready") ==
             {:error, {:invalid_role_outcome, :archivist, "plan_ready"}}

    assert Lifecycle.transition(:planner, "accept") ==
             {:error, {:invalid_role_outcome, :planner, "accept"}}

    assert Lifecycle.transition(:not_a_role, "plan") == {:error, {:unknown_role, :not_a_role}}
    assert Lifecycle.transition("NOT_A_ROLE", "plan") == {:error, {:unknown_role, "NOT_A_ROLE"}}

    assert Lifecycle.transition(:planner, :not_an_outcome) ==
             {:error, {:invalid_role_outcome, :planner, "not_an_outcome"}}

    assert Lifecycle.transition(:planner, %{}) ==
             {:error, {:invalid_role_outcome, :planner, %{}}}

    assert Lifecycle.transition(:pm, "converge", %{
             pm_phase: :returning,
             completed_working_round?: true,
             preceding_adversary_findings: :malformed
           }) == {:error, :blocking_adversary_findings}

    assert Lifecycle.transition(:pm, "converge", %{
             pm_phase: :returning,
             completed_working_round?: true,
             preceding_adversary_findings: [:malformed]
           }) == {:error, :blocking_adversary_findings}
  end

  test "role result validation is strict and does not accept model routing authority" do
    assert {:ok, result} = Lifecycle.validate_result(valid_result("REVIEWER", "accept"))
    assert result["schema"] == "symphony.role-result/v1"

    assert {:error, {:unknown_role_result_fields, ["next_role"]}} =
             Lifecycle.validate_result(Map.put(valid_result("REVIEWER", "accept"), "next_role", "IMPLEMENTER"))

    assert {:error, {:missing_role_result_fields, missing}} =
             Lifecycle.validate_result(Map.delete(valid_result("REVIEWER", "accept"), "findings"))

    assert "findings" in missing

    assert {:error, {:invalid_role_result_schema, "wrong/v1"}} =
             Lifecycle.validate_result(Map.put(valid_result("REVIEWER", "accept"), "schema", "wrong/v1"))

    assert {:error, {:invalid_role_result_role, "ARCHITECT"}} =
             Lifecycle.validate_result(valid_result("ARCHITECT", "accept"))

    assert {:error, {:invalid_role_outcome, :reviewer, "plan_ready"}} =
             Lifecycle.validate_result(valid_result("REVIEWER", "plan_ready"))

    assert {:error, :empty_role_result_summary} =
             Lifecycle.validate_result(Map.put(valid_result("REVIEWER", "accept"), "summary", "  "))

    assert {:error, :invalid_role_result_summary} =
             Lifecycle.validate_result(Map.put(valid_result("REVIEWER", "accept"), "summary", 12))

    assert {:error, :role_result_summary_too_long} =
             Lifecycle.validate_result(Map.put(valid_result("REVIEWER", "accept"), "summary", String.duplicate("x", 4_001)))

    assert {:error, :invalid_role_result_evidence} =
             Lifecycle.validate_result(Map.put(valid_result("REVIEWER", "accept"), "evidence", ["", 12]))

    assert {:error, :invalid_role_result_evidence} =
             Lifecycle.validate_result(Map.put(valid_result("REVIEWER", "accept"), "evidence", :none))

    assert {:error, :invalid_role_result_findings} =
             Lifecycle.validate_result(Map.put(valid_result("REVIEWER", "accept"), "findings", :none))

    assert {:error, :role_result_not_a_map} = Lifecycle.validate_result(:not_a_result)

    valid_finding = %{
      "severity" => "advisory",
      "summary" => "useful finding",
      "evidence" => []
    }

    assert {:ok, _} =
             Lifecycle.validate_result(Map.put(valid_result("REVIEWER", "accept"), "findings", [valid_finding]))

    assert {:error, :invalid_finding} =
             Lifecycle.validate_result(Map.put(valid_result("REVIEWER", "accept"), "findings", [:bad]))

    assert {:error, :invalid_finding_summary} =
             Lifecycle.validate_result(Map.put(valid_result("REVIEWER", "accept"), "findings", [Map.put(valid_finding, "summary", 12)]))

    assert {:error, :invalid_finding_evidence} =
             Lifecycle.validate_result(Map.put(valid_result("REVIEWER", "accept"), "findings", [Map.put(valid_finding, "evidence", :bad)]))
  end

  test "role result decoding accepts exactly one expected-role JSON object" do
    encoded = Jason.encode!(valid_result("REVIEWER", "accept"))

    assert {:ok, result} = Lifecycle.decode_and_validate_result("  #{encoded}\n", :reviewer)
    assert result["role"] == "REVIEWER"
  end

  test "role result decoding rejects missing, fenced, prose, malformed, and non-object output" do
    encoded = Jason.encode!(valid_result("REVIEWER", "accept"))

    assert {:error, :missing_role_result_output} = Lifecycle.decode_and_validate_result("  ", :reviewer)

    assert {:error, {:role_result_json_decode_error, _}} =
             Lifecycle.decode_and_validate_result("```json\n#{encoded}\n```", :reviewer)

    assert {:error, {:role_result_json_decode_error, _}} =
             Lifecycle.decode_and_validate_result("Here is the result: #{encoded}", :reviewer)

    assert {:error, {:role_result_json_decode_error, _}} =
             Lifecycle.decode_and_validate_result("{not json}", :reviewer)

    assert {:error, :role_result_not_a_map} = Lifecycle.decode_and_validate_result("[]", :reviewer)
    assert {:error, :invalid_role_result_output} = Lifecycle.decode_and_validate_result([], :reviewer)
  end

  test "legal outcomes expose the canonical profile contract" do
    assert Lifecycle.legal_outcomes(:planner) == ["plan_ready", "await_human"]
  end

  test "role result decoding enforces the host-selected role" do
    assert {:error, {:role_result_role_mismatch, "REVIEWER", "IMPLEMENTER"}} =
             Lifecycle.decode_and_validate_result(
               Jason.encode!(valid_result("IMPLEMENTER", "implementation_complete")),
               :reviewer
             )
  end

  test "orchestrator retries a rejected role result as a role contract failure" do
    issue = %Issue{id: "issue-contract", identifier: "MT-CONTRACT", url: "https://example.test/issue-contract"}
    ref = make_ref()

    running_entry = %{
      ref: ref,
      pid: self(),
      identifier: issue.identifier,
      issue: issue,
      role: :reviewer,
      retry_attempt: 0,
      worker_host: nil,
      workspace_path: nil,
      session_id: "session-contract",
      started_at: DateTime.utc_now()
    }

    state = %Orchestrator.State{
      running: %{issue.id => running_entry},
      claimed: MapSet.new([issue.id]),
      retry_attempts: %{},
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }

    {:noreply, state} =
      Orchestrator.handle_info(
        {:role_execution_failed, issue.id, %{kind: :role_result_contract, role: :reviewer, reason: {:invalid_role_result, :invalid_finding_evidence}}},
        state
      )

    assert state.running[issue.id].role_execution_failure.kind == :role_result_contract

    {:noreply, state} = Orchestrator.handle_info({:DOWN, ref, :process, self(), :normal}, state)
    assert state.running == %{}
    assert %{error: error, timer_ref: timer_ref} = state.retry_attempts[issue.id]
    assert error =~ "role result contract rejected"
    Process.cancel_timer(timer_ref)
  end

  test "finding severity, human question, and transition result validation are bounded" do
    base = valid_result("REVIEWER", "accept")

    assert {:error, {:unknown_finding_fields, ["extra"]}} =
             Lifecycle.validate_result(Map.put(base, "findings", [%{"severity" => "advisory", "summary" => "ok", "evidence" => [], "extra" => true}]))

    assert {:error, {:missing_finding_fields, ["evidence"]}} =
             Lifecycle.validate_result(Map.put(base, "findings", [%{"severity" => "advisory", "summary" => "ok"}]))

    assert {:error, :invalid_finding_severity} =
             Lifecycle.validate_result(Map.put(base, "findings", [%{"severity" => "critical", "summary" => "bad", "evidence" => []}]))

    assert {:error, :invalid_finding_summary} =
             Lifecycle.validate_result(Map.put(base, "findings", [%{"severity" => "advisory", "summary" => "", "evidence" => []}]))

    assert {:error, :invalid_finding_evidence} =
             Lifecycle.validate_result(Map.put(base, "findings", [%{"severity" => "advisory", "summary" => "bad", "evidence" => [1]}]))

    await_result = valid_result("PM", "await_human")
    assert {:error, :missing_human_question} = Lifecycle.validate_result(await_result)
    assert {:ok, _} = Lifecycle.validate_result(Map.put(await_result, "human_question", "Choose a product direction."))

    assert {:error, :unexpected_human_question} =
             Lifecycle.validate_result(Map.put(base, "human_question", "not allowed"))

    transition_result = Map.put(valid_result("PLANNER", "plan_ready"), "human_question", nil)

    assert {:ok, %{from_role: :planner, to_role: :reviewer}} =
             Lifecycle.transition_for_result(transition_result)
  end

  defp valid_result(role, outcome) do
    %{
      "schema" => "symphony.role-result/v1",
      "role" => role,
      "outcome" => outcome,
      "summary" => "bounded result",
      "evidence" => ["observed evidence"],
      "findings" => []
    }
  end
end
