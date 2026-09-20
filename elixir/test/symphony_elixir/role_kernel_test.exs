defmodule SymphonyElixir.RoleKernelTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{LifecycleHistory, RoleRuntimePolicy}

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
    refute RoleProfiles.result_contract_instructions(:planner) =~ "Planner revision reconciliation"
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

      assert prompt =~
               "summary\" must be a non-empty JSON string of at most #{RoleProfiles.role_result_summary_max_length()} characters"

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

    assert prompt =~ "\"round\": 2"
    assert prompt =~ "\"findings\": ["
    assert prompt =~ "\"advisory\""

    returning_pm_prompt =
      PromptBuilder.build_prompt(issue, :pm, %{
        handoff: %{reconciliation: %{required_transition_ids: ["life:r1:p1:ADVERSARY:review_complete"]}},
        correction_feedback: ":invalid_reconciliation_reference"
      })

    assert returning_pm_prompt =~ "Host-projected evidence reconciliation"
    assert returning_pm_prompt =~ "life:r1:p1:ADVERSARY:review_complete"
    assert returning_pm_prompt =~ "Host correction diagnostic"
    assert returning_pm_prompt =~ "PM reconciliation contract"

    resumed_pm_prompt =
      PromptBuilder.build_prompt(issue, :pm, %{
        lifecycle_context: %{
          human_guidance: %{
            "response_transition_id" => "life:epoch1:human_response",
            "decision" => "continue",
            "text" => "Continue with the constrained correction.",
            "authorized_actions" => [],
            "provenance" => %{"comment_id" => 77, "author_id" => 7001}
          }
        }
      })

    assert resumed_pm_prompt =~ "Host-accepted human guidance"
    assert resumed_pm_prompt =~ "life:epoch1:human_response"
    assert resumed_pm_prompt =~ "Continue with the constrained correction."

    planner_revision_prompt =
      PromptBuilder.build_prompt(issue, :planner, %{
        handoff: %{
          revision_reconciliation: %{
            rejected_planner: %{summary: "Original plan"},
            reviewer: %{summary: "Exact command is required"},
            reviewer_findings: [%{"finding_ref" => "life:r1:p1:REVIEWER:revise:finding:0"}]
          }
        }
      })

    assert planner_revision_prompt =~ "Planner revision reconciliation"
    assert planner_revision_prompt =~ "Compare the rejected plan against every Reviewer finding"
    assert planner_revision_prompt =~ "life:r1:p1:REVIEWER:revise:finding:0"
    assert planner_revision_prompt =~ "Do not require yourself to execute verification owned by the Implementer"

    refute PromptBuilder.build_prompt(issue, :planner) =~ "Planner revision reconciliation"

    {:ok, reviewer_policy} = RoleRuntimePolicy.for_role(:reviewer, "/tmp/issue-workspace")

    prompt_with_authority =
      PromptBuilder.build_prompt(issue, :reviewer, %{
        role_profile: RoleProfiles.profile!(:reviewer),
        runtime_authority: RoleRuntimePolicy.snapshot(reviewer_policy)
      })

    assert prompt_with_authority =~ "Host-enforced runtime authority:"
    assert prompt_with_authority =~ "\"write_authority\": \"read_only\""
    assert prompt_with_authority =~ "\"sandbox_mode\": \"readOnly\""
    assert prompt_with_authority =~ "\"network_enabled\": false"
    assert prompt_with_authority =~ "\"model_tracker_tools\": \"disabled\""

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

  test "reviewer lifecycle context describes pre-implementation plan review" do
    context =
      Lifecycle.lifecycle_context(
        lifecycle_state(:reviewer, :planner,
          round: 2,
          planning_attempt: 1,
          pm_phase: :returning,
          completed_working_round?: true
        )
      )

    assert context.current_role == "REVIEWER"
    assert context.lifecycle_position == "pre_implementation_plan_review"
    assert context.predecessor == "PLANNER"
    assert context.object_received == "Planner's proposed implementation plan"
    assert context.object_produced == "plan acceptance or revision result"
    assert context.implementation_status == "not_started"
    assert "Implementer has not executed the proposed plan." in context.not_yet_happened
    assert context.temporal_interpretation =~ "absence of planned mutations is expected"

    assert %{destination: "IMPLEMENTER", available_now?: true} =
             Enum.find(context.outcome_routes, &(&1.outcome == "accept"))

    assert %{destination: "PLANNER", available_now?: true} =
             Enum.find(context.outcome_routes, &(&1.outcome == "revise"))

    issue = %Issue{identifier: "T-REVIEW", title: "Plan review"}
    prompt = PromptBuilder.build_prompt(issue, :reviewer, %{lifecycle_context: context})

    assert prompt =~ "Host-derived lifecycle context:"
    assert prompt =~ "\"current_role\": \"REVIEWER\""
    assert prompt =~ "\"object_received\": \"Planner's proposed implementation plan\""
    assert prompt =~ "\"implementation_status\": \"not_started\""
    assert prompt =~ "absence of planned mutations is expected"
  end

  test "Planner revision reconciliation is structural and outcome-sensitive" do
    base = valid_result("PLANNER", "plan_ready")

    reconciliation = %{
      "rejected_planner_transition_id" => "life:r1:p1:PLANNER:plan_ready",
      "reviewer_transition_id" => "life:r1:p1:REVIEWER:revise",
      "finding_responses" => [
        %{
          "finding_ref" => "life:r1:p1:REVIEWER:revise:finding:0",
          "assessment" => "The finding identifies a genuine defect.",
          "plan_excerpt" => "bounded result"
        }
      ]
    }

    assert {:ok, _} = Lifecycle.validate_result(Map.put(base, "revision_reconciliation", reconciliation))

    await_human =
      valid_result("PLANNER", "await_human")
      |> Map.put("human_question", "Authorize the missing external capability.")
      |> Map.put("revision_reconciliation", put_in(reconciliation, ["finding_responses", Access.at(0), "plan_excerpt"], nil))

    assert {:ok, _} = Lifecycle.validate_result(await_human)

    non_converged =
      valid_result("PLANNER", "non_converged")
      |> Map.put("revision_reconciliation", put_in(reconciliation, ["finding_responses", Access.at(0), "plan_excerpt"], nil))

    assert {:ok, _} = Lifecycle.validate_result(non_converged)

    assert {:error, {:revision_reconciliation_not_allowed_for_role, :reviewer}} =
             Lifecycle.validate_result(Map.put(valid_result("REVIEWER", "revise"), "revision_reconciliation", reconciliation))
  end

  test "Planner revision reconciliation schema rejects malformed response shapes" do
    base = valid_result("PLANNER", "plan_ready")

    reconciliation = %{
      "rejected_planner_transition_id" => "life:r1:p1:PLANNER:plan_ready",
      "reviewer_transition_id" => "life:r1:p1:REVIEWER:revise",
      "finding_responses" => [
        %{
          "finding_ref" => "life:r1:p1:REVIEWER:revise:finding:0",
          "assessment" => "The finding identifies a genuine defect.",
          "plan_excerpt" => "bounded result"
        }
      ]
    }

    assert {:error, :invalid_revision_reconciliation} =
             Lifecycle.validate_result(Map.put(base, "revision_reconciliation", []))

    assert {:error, {:unknown_revision_reconciliation_fields, _}} =
             Lifecycle.validate_result(Map.put(base, "revision_reconciliation", Map.put(reconciliation, "extra", true)))

    assert {:error, {:missing_revision_reconciliation_fields, _}} =
             Lifecycle.validate_result(Map.put(base, "revision_reconciliation", Map.delete(reconciliation, "reviewer_transition_id")))

    malformed_ids = Map.put(reconciliation, "rejected_planner_transition_id", "")

    assert {:error, {:invalid_revision_reconciliation, {:empty_field, :rejected_planner_transition_id}}} =
             Lifecycle.validate_result(Map.put(base, "revision_reconciliation", malformed_ids))

    malformed_ids = Map.put(reconciliation, "reviewer_transition_id", 123)

    assert {:error, {:invalid_revision_reconciliation, {:invalid_field, :reviewer_transition_id}}} =
             Lifecycle.validate_result(Map.put(base, "revision_reconciliation", malformed_ids))

    assert {:error, :invalid_revision_finding_responses} =
             Lifecycle.validate_result(Map.put(base, "revision_reconciliation", Map.put(reconciliation, "finding_responses", %{})))

    assert {:error, :invalid_revision_finding_response} =
             Lifecycle.validate_result(Map.put(base, "revision_reconciliation", Map.put(reconciliation, "finding_responses", [nil])))

    malformed_response =
      put_in(reconciliation, ["finding_responses", Access.at(0)], %{
        "finding_ref" => "life:r1:p1:REVIEWER:revise:finding:0",
        "assessment" => "",
        "plan_excerpt" => "bounded result"
      })

    assert {:error, {:invalid_revision_reconciliation, {:empty_field, :assessment}}} =
             Lifecycle.validate_result(Map.put(base, "revision_reconciliation", malformed_response))

    malformed_response =
      put_in(reconciliation, ["finding_responses", Access.at(0)], %{
        "finding_ref" => "life:r1:p1:REVIEWER:revise:finding:0",
        "assessment" => "The finding identifies a genuine defect.",
        "plan_excerpt" => "bounded result",
        "extra" => true
      })

    assert {:error, {:unknown_revision_finding_response_fields, _}} =
             Lifecycle.validate_result(Map.put(base, "revision_reconciliation", malformed_response))

    malformed_response =
      put_in(reconciliation, ["finding_responses", Access.at(0)], %{
        "finding_ref" => "life:r1:p1:REVIEWER:revise:finding:0",
        "assessment" => "The finding identifies a genuine defect."
      })

    assert {:error, {:missing_revision_finding_response_fields, _}} =
             Lifecycle.validate_result(Map.put(base, "revision_reconciliation", malformed_response))

    malformed_response =
      put_in(reconciliation, ["finding_responses", Access.at(0)], %{
        "finding_ref" => 123,
        "assessment" => "The finding identifies a genuine defect.",
        "plan_excerpt" => "bounded result"
      })

    assert {:error, {:invalid_revision_reconciliation, {:invalid_field, :finding_ref}}} =
             Lifecycle.validate_result(Map.put(base, "revision_reconciliation", malformed_response))

    plan_without_excerpt =
      put_in(reconciliation, ["finding_responses", Access.at(0), "plan_excerpt"], nil)

    assert {:error, {:invalid_revision_reconciliation, {:invalid_field, :plan_excerpt}}} =
             Lifecycle.validate_result(Map.put(base, "revision_reconciliation", plan_without_excerpt))

    await_human =
      valid_result("PLANNER", "await_human")
      |> Map.put("human_question", "Authorize the missing external capability.")
      |> Map.put("revision_reconciliation", reconciliation)

    assert {:error, {:unexpected_revision_plan_excerpt, "await_human"}} =
             Lifecycle.validate_result(await_human)

    non_converged =
      valid_result("PLANNER", "non_converged")
      |> Map.put("revision_reconciliation", reconciliation)

    assert {:error, {:unexpected_revision_plan_excerpt, "non_converged"}} =
             Lifecycle.validate_result(non_converged)
  end

  test "lifecycle context describes the generic role metamap without changing routing" do
    assertions = [
      {:planner, :pm, "proposed implementation plan", "not_started", "REVIEWER"},
      {:implementer, :reviewer, "implemented project seam", "in_progress", "ADVERSARY"},
      {:adversary, :implementer, "adversarial review result", "completed", "PM"},
      {:archivist, :pm, "archival and continuity result", "completed", "LIFECYCLE_COMPLETE"}
    ]

    for {role, predecessor, object_produced, implementation_status, destination} <- assertions do
      context = Lifecycle.lifecycle_context(lifecycle_state(role, predecessor))

      assert context.current_role == RoleProfiles.role_name(role)
      assert context.object_produced == object_produced
      assert context.implementation_status == implementation_status

      assert Enum.any?(context.outcome_routes, fn route ->
               route.destination == destination
             end)
    end

    planner_context = Lifecycle.lifecycle_context(lifecycle_state(:planner, :pm))
    assert planner_context.temporal_interpretation =~ "do not treat its proposed mutations as already applied"

    returning_pm =
      Lifecycle.lifecycle_context(
        lifecycle_state(:pm, :adversary,
          round: 2,
          planning_attempt: 1,
          pm_phase: :returning,
          completed_working_round?: true
        )
      )

    assert returning_pm.lifecycle_position == "returning_pm"
    assert returning_pm.object_received == "completed working-round evidence, especially the Adversary result"
    assert Enum.any?(returning_pm.outcome_routes, &(&1.destination == "PLANNER"))
    assert Enum.any?(returning_pm.outcome_routes, &(&1.destination == "ARCHIVIST"))
  end

  test "reconstructed lifecycle history produces stable lifecycle context" do
    lifecycle_id = "lifecycle-context-1"

    comments = [
      LifecycleHistory.render(LifecycleHistory.start_event(lifecycle_id)),
      LifecycleHistory.render(reconstructed_transition(lifecycle_id, "PM", "plan", "PLANNER", 1, 1)),
      LifecycleHistory.render(reconstructed_transition(lifecycle_id, "PLANNER", "plan_ready", "REVIEWER", 1, 1))
    ]

    assert {:ok, history_after_restart} = LifecycleHistory.from_comments(comments)
    assert {:ok, history_after_second_restart} = LifecycleHistory.from_comments(comments)

    assert Lifecycle.lifecycle_context(history_after_restart) ==
             Lifecycle.lifecycle_context(history_after_second_restart)
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

    max_summary = String.duplicate("x", RoleProfiles.role_result_summary_max_length())

    assert {:ok, _} =
             Lifecycle.validate_result(Map.put(valid_result("REVIEWER", "accept"), "summary", max_summary))

    assert {:error, :role_result_summary_too_long} =
             Lifecycle.validate_result(
               Map.put(
                 valid_result("REVIEWER", "accept"),
                 "summary",
                 max_summary <> "x"
               )
             )

    assert {:error, :invalid_role_result_evidence} =
             Lifecycle.validate_result(Map.put(valid_result("REVIEWER", "accept"), "evidence", ["", 12]))

    assert {:error, :invalid_role_result_evidence} =
             Lifecycle.validate_result(Map.put(valid_result("REVIEWER", "accept"), "evidence", :none))

    assert {:error, :invalid_role_result_findings} =
             Lifecycle.validate_result(Map.put(valid_result("REVIEWER", "accept"), "findings", :none))

    assert {:error, :invalid_human_guidance_acknowledgment} =
             Lifecycle.validate_result(Map.put(valid_result("REVIEWER", "accept"), "human_guidance_acknowledgment", %{}))

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
    assert Lifecycle.legal_outcomes(:planner) == ["plan_ready", "non_converged", "await_human"]
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

  test "repeated PM contract failure reaches a bounded block without retaining the rejected result" do
    issue = %Issue{id: "issue-pm-contract", identifier: "MT-PM-CONTRACT", url: "https://example.test/issue-pm-contract"}
    ref = make_ref()

    running_entry = %{
      ref: ref,
      pid: self(),
      identifier: issue.identifier,
      issue: issue,
      role: :pm,
      correction_attempt: 3,
      retry_attempt: 0,
      worker_host: nil,
      workspace_path: nil,
      session_id: "session-pm-contract",
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
        {:role_execution_failed, issue.id, %{kind: :role_result_contract, role: :pm, reason: :missing_pm_escalation_basis}},
        state
      )

    {:noreply, state} = Orchestrator.handle_info({:DOWN, ref, :process, self(), :normal}, state)

    assert state.running == %{}
    assert state.retry_attempts == %{}
    assert state.blocked[issue.id].role_execution == nil
  end

  test "Planner revision contract correction is bounded independently and does not add lifecycle state" do
    issue = %Issue{id: "issue-planner-contract", identifier: "MT-PLANNER-CONTRACT", url: "https://example.test/issue-planner-contract"}
    ref = make_ref()

    running_entry = %{
      ref: ref,
      pid: self(),
      identifier: issue.identifier,
      issue: issue,
      role: :planner,
      correction_attempt: 0,
      retry_attempt: 0,
      worker_host: nil,
      workspace_path: nil,
      session_id: "session-planner-contract",
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
        {:role_execution_failed, issue.id, %{kind: :role_result_contract, role: :planner, reason: :missing_returning_planner_revision_reconciliation}},
        state
      )

    {:noreply, state} = Orchestrator.handle_info({:DOWN, ref, :process, self(), :normal}, state)
    assert state.running == %{}
    assert %{error: error, correction_feedback: feedback, correction_attempt: correction_attempt, timer_ref: timer_ref} = state.retry_attempts[issue.id]
    assert error =~ "Planner result contract correction required"
    assert feedback =~ "missing_returning_planner_revision_reconciliation"
    assert correction_attempt == 1
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

    reconciliation = %{
      "considered_transition_ids" => ["life:r1:p1:IMPLEMENTER:implementation_complete"],
      "assessment" => "The accepted report was considered with its evidentiary limits."
    }

    assert {:ok, _} = Lifecycle.validate_result(Map.put(valid_result("PM", "plan"), "reconciliation", reconciliation))

    assert {:error, {:duplicate_reconciliation_reference, :considered_transition_ids}} =
             Lifecycle.validate_result(
               Map.put(
                 valid_result("PM", "plan"),
                 "reconciliation",
                 %{reconciliation | "considered_transition_ids" => ["same", "same"]}
               )
             )

    escalation_basis = %{
      "required_external_action" => "Authorize the external fixture.",
      "existing_authority_gap" => "Current authority cannot provide it.",
      "supporting_transition_ids" => []
    }

    assert {:ok, _} =
             Lifecycle.validate_result(
               valid_result("PM", "await_human")
               |> Map.put("human_question", "Authorize the external fixture.")
               |> Map.put("escalation_basis", escalation_basis)
             )

    transition_result = Map.put(valid_result("PLANNER", "plan_ready"), "human_question", nil)

    assert {:ok, %{from_role: :planner, to_role: :reviewer}} =
             Lifecycle.transition_for_result(transition_result)
  end

  test "role contract edge cases remain explicitly validated" do
    pm_plan = valid_result("PM", "plan")

    base_reconciliation = %{
      "considered_transition_ids" => ["life:r1:p1:IMPLEMENTER:implementation_complete"],
      "assessment" => "The accepted report was considered."
    }

    assert {:error, {:unknown_reconciliation_fields, ["extra"]}} =
             Lifecycle.validate_result(Map.put(pm_plan, "reconciliation", Map.put(base_reconciliation, "extra", true)))

    assert {:error, {:missing_reconciliation_fields, ["assessment"]}} =
             Lifecycle.validate_result(Map.put(pm_plan, "reconciliation", Map.delete(base_reconciliation, "assessment")))

    assert {:error, :invalid_reconciliation} = Lifecycle.validate_result(Map.put(pm_plan, "reconciliation", "bad"))

    assert {:error, {:reconciliation_not_allowed_for_role, :reviewer}} =
             Lifecycle.validate_result(Map.put(valid_result("REVIEWER", "accept"), "reconciliation", base_reconciliation))

    await_pm = Map.put(valid_result("PM", "await_human"), "human_question", "Supply authorization.")

    basis = %{
      "required_external_action" => "Authorize the external fixture.",
      "existing_authority_gap" => "Current authority cannot provide it.",
      "supporting_transition_ids" => []
    }

    assert {:error, {:unknown_escalation_basis_fields, ["extra"]}} =
             Lifecycle.validate_result(Map.put(await_pm, "escalation_basis", Map.put(basis, "extra", true)))

    assert {:error, {:missing_escalation_basis_fields, ["existing_authority_gap"]}} =
             Lifecycle.validate_result(Map.put(await_pm, "escalation_basis", Map.delete(basis, "existing_authority_gap")))

    assert {:error, :invalid_escalation_basis} = Lifecycle.validate_result(Map.put(await_pm, "escalation_basis", "bad"))

    assert {:error, :unexpected_escalation_basis} =
             Lifecycle.validate_result(Map.put(pm_plan, "escalation_basis", basis))

    assert {:error, {:escalation_basis_not_allowed_for_role, :reviewer}} =
             Lifecycle.validate_result(Map.put(valid_result("REVIEWER", "accept"), "escalation_basis", basis))

    resolved = prerequisite_report("resolved")

    assert {:error, {:prerequisite_resolution_not_allowed_for_role, :implementer}} =
             Lifecycle.validate_result(Map.put(valid_result("IMPLEMENTER", "implementation_complete"), "prerequisite_resolution", resolved))

    assert {:error, :invalid_prerequisite_resolution} =
             Lifecycle.validate_result(Map.put(valid_result("PLANNER", "plan_ready"), "prerequisite_resolution", "bad"))

    assert {:error, :invalid_prerequisite_alternatives} =
             Lifecycle.validate_result(Map.put(valid_result("PLANNER", "plan_ready"), "prerequisite_resolution", Map.put(resolved, "alternatives", [])))

    assert {:error, {:unknown_prerequisite_alternative_fields, ["extra"]}} =
             Lifecycle.validate_result(
               Map.put(
                 valid_result("PLANNER", "plan_ready"),
                 "prerequisite_resolution",
                 Map.put(resolved, "alternatives", [Map.put(List.first(resolved["alternatives"]), "extra", true)])
               )
             )

    assert {:error, :invalid_prerequisite_alternative} =
             Lifecycle.validate_result(Map.put(valid_result("PLANNER", "plan_ready"), "prerequisite_resolution", Map.put(resolved, "alternatives", [:bad])))

    invalid_approach = Map.put(List.first(resolved["alternatives"]), "approach", 12)

    assert {:error, {:invalid_prerequisite_field, :alternative_approach}} =
             Lifecycle.validate_result(
               Map.put(resolved, "alternatives", [invalid_approach])
               |> then(&Map.put(valid_result("PLANNER", "plan_ready"), "prerequisite_resolution", &1))
             )

    invalid_evidence = Map.put(List.first(resolved["alternatives"]), "evidence", :bad)

    assert {:error, {:invalid_prerequisite_list, :alternative_evidence}} =
             Lifecycle.validate_result(
               Map.put(resolved, "alternatives", [invalid_evidence])
               |> then(&Map.put(valid_result("PLANNER", "plan_ready"), "prerequisite_resolution", &1))
             )

    inconsistent = Map.put(resolved, "authority_status", "requires_external_action")

    assert {:error, :inconsistent_prerequisite_resolution} =
             Lifecycle.validate_result(Map.put(valid_result("PLANNER", "plan_ready"), "prerequisite_resolution", inconsistent))

    assert Lifecycle.prerequisite_resolution_complete?(prerequisite_report("no_feasible_authorized_path_established"))
    assert Lifecycle.prerequisite_progress(%{}, %{}) == :not_applicable
    assert Lifecycle.prerequisite_context(:not_a_state) == %{}
    assert Lifecycle.lifecycle_context(:not_a_state) == %{}
    assert Lifecycle.lifecycle_context(%{current_role: :pm})[:predecessor] == nil
    assert Lifecycle.lifecycle_context(%{current_role: :unknown}) == %{}

    assert {:error, {:invalid_reconciliation_list, :considered_transition_ids}} =
             Lifecycle.validate_result(Map.put(pm_plan, "reconciliation", Map.put(base_reconciliation, "considered_transition_ids", :bad)))
  end

  test "lifecycle context retains correction, predecessor, and fallback descriptions" do
    report = prerequisite_report("unresolved")

    correction = %{
      "round" => 1,
      "planning_attempt" => 1,
      "role" => "REVIEWER",
      "from_role" => "REVIEWER",
      "outcome" => "revise",
      "prerequisite_resolution" => report,
      "summary" => "The prerequisite remains unresolved.",
      "evidence" => ["review evidence"]
    }

    attempted = %{
      "round" => 1,
      "planning_attempt" => 2,
      "role" => "PLANNER",
      "from_role" => "PLANNER",
      "outcome" => "plan_ready",
      "prerequisite_resolution" => report,
      "summary" => "The plan remains bounded.",
      "evidence" => ["planner evidence"]
    }

    context =
      Lifecycle.lifecycle_context(%{
        current_role: :planner,
        round: 1,
        planning_attempt: 2,
        pm_phase: nil,
        events: [correction]
      })

    assert context.lifecycle_position == "planning_correction"
    assert context.object_received == "Reviewer correction request"
    assert context.already_happened == ["Reviewer produced a correction request for this planning attempt."]
    assert context.temporal_interpretation =~ "corrected proposed plan"
    assert context.prerequisite_context.attempted_resolution == nil

    attempted_context =
      Lifecycle.prerequisite_context(%{
        current_role: :planner,
        round: 1,
        planning_attempt: 2,
        events: [correction, attempted]
      })

    assert attempted_context.attempted_resolution.prerequisite_resolution == report

    assert Lifecycle.prerequisite_context(%{
             current_role: :planner,
             round: 1,
             planning_attempt: 2,
             events: [correction, Map.delete(attempted, "prerequisite_resolution")]
           }).attempted_resolution == nil

    assert Lifecycle.prerequisite_progress(
             %{events: [%{"round" => 1, "planning_attempt" => 2, "role" => "OTHER"}], round: 1, planning_attempt: 0},
             Map.put(valid_result("REVIEWER", "revise"), "prerequisite_resolution", report)
           ) == :material

    assert Lifecycle.prerequisite_progress(
             %{events: [%{"round" => 1, "planning_attempt" => 2, "role" => "OTHER"}], round: 1, planning_attempt: 3},
             Map.put(valid_result("REVIEWER", "revise"), "prerequisite_resolution", report)
           ) == :material

    assert Lifecycle.lifecycle_context(%{current_role: :pm, events: [%{"from_role" => "PLANNER"}]})
           |> Map.take([:already_happened, :not_yet_happened]) == %{already_happened: [], not_yet_happened: []}
  end

  test "prerequisite resolution is structured and controls specialist dispositions" do
    resolved = prerequisite_report("resolved")
    unresolved = prerequisite_report("unresolved")
    exhausted = prerequisite_report("no_feasible_authorized_path_established")

    external =
      prerequisite_report("external_prerequisite")
      |> Map.put("authority_status", "requires_external_action")

    assert {:ok, _} =
             Lifecycle.validate_result(Map.put(valid_result("PLANNER", "plan_ready"), "prerequisite_resolution", resolved))

    assert {:ok, %{to_role: :reviewer}} =
             Lifecycle.transition_for_result(Map.put(valid_result("PLANNER", "plan_ready"), "prerequisite_resolution", resolved))

    assert {:error, {:unknown_prerequisite_resolution_fields, ["extra"]}} =
             Lifecycle.validate_result(
               Map.put(
                 valid_result("PLANNER", "plan_ready"),
                 "prerequisite_resolution",
                 Map.put(resolved, "extra", true)
               )
             )

    assert {:error, :plan_ready_has_unresolved_prerequisite} =
             Lifecycle.transition_for_result(Map.put(valid_result("PLANNER", "plan_ready"), "prerequisite_resolution", unresolved))

    assert {:ok, %{to_role: :non_converged}} =
             Lifecycle.transition_for_result(Map.put(valid_result("PLANNER", "non_converged"), "prerequisite_resolution", exhausted))

    assert {:ok, %{to_role: :await_human}} =
             Lifecycle.transition_for_result(
               Map.put(
                 Map.put(valid_result("PLANNER", "await_human"), "human_question", "Supply the missing artifact."),
                 "prerequisite_resolution",
                 external
               )
             )

    assert {:error, :await_human_requires_specific_external_prerequisite} =
             Lifecycle.transition_for_result(
               Map.put(
                 Map.put(valid_result("PLANNER", "await_human"), "human_question", "Investigate this further."),
                 "prerequisite_resolution",
                 unresolved
               )
             )

    incomplete_alternative = Map.put(List.first(exhausted["alternatives"]), "disposition", "unexamined")
    incomplete = Map.put(exhausted, "alternatives", [incomplete_alternative])

    assert {:error, :incomplete_prerequisite_non_convergence} =
             Lifecycle.transition_for_result(Map.put(valid_result("PLANNER", "non_converged"), "prerequisite_resolution", incomplete))
  end

  test "prerequisite context reconstructs the correction and exact progress frontier" do
    report = prerequisite_report("unresolved")

    state = %{
      current_role: :planner,
      round: 1,
      planning_attempt: 2,
      events: [
        %{
          "round" => 1,
          "planning_attempt" => 1,
          "role" => "REVIEWER",
          "outcome" => "revise",
          "summary" => "The prerequisite remains unestablished.",
          "evidence" => ["review evidence"],
          "prerequisite_resolution" => report
        }
      ]
    }

    context = Lifecycle.prerequisite_context(state)
    assert context.required?
    assert context.preceding_correction.prerequisite_resolution == report
    assert context.outstanding_evidence_frontier == ["The governing task contract requires the capability."]

    history = %{
      round: 1,
      planning_attempt: 3,
      events: [
        %{"round" => 1, "planning_attempt" => 2, "role" => "PLANNER", "prerequisite_resolution" => report},
        %{"round" => 1, "planning_attempt" => 2, "role" => "REVIEWER", "prerequisite_resolution" => report},
        %{"round" => 1, "planning_attempt" => 3, "role" => "PLANNER", "prerequisite_resolution" => report}
      ]
    }

    reviewer_result =
      valid_result("REVIEWER", "revise")
      |> Map.put("prerequisite_resolution", report)

    assert Lifecycle.prerequisite_progress(history, reviewer_result) == :unchanged

    changed_alternative = Map.put(List.first(report["alternatives"]), "approach", "new authorized mechanism")
    changed = Map.put(report, "alternatives", [changed_alternative])
    assert Lifecycle.prerequisite_progress(history, Map.put(reviewer_result, "prerequisite_resolution", changed)) == :material
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

  defp prerequisite_report(status) do
    %{
      "blocked_objective" => "Complete the authorized lifecycle change.",
      "missing_prerequisite" => "A required capability has not been established.",
      "absence_evidence" => ["The capability was not present in the inspected state."],
      "authoritative_requirement" => ["The governing task contract requires the capability."],
      "alternatives" => [
        %{
          "approach" => "Use the documented mechanism.",
          "evidence" => ["The mechanism was inspected and did not establish the prerequisite."],
          "disposition" => if(status == "resolved", do: "available", else: "demonstrated_infeasible")
        }
      ],
      "authority_status" => if(status == "resolved", do: "within_existing_authority", else: "not_resolvable_with_existing_authority"),
      "unlock_action" => "Supply evidence or capability for the missing prerequisite.",
      "resolution_status" => status
    }
  end

  defp lifecycle_state(role, predecessor, overrides \\ []) do
    %{
      current_role: role,
      round: Keyword.get(overrides, :round, 1),
      planning_attempt: Keyword.get(overrides, :planning_attempt, 1),
      pm_phase: Keyword.get(overrides, :pm_phase, :returning),
      completed_working_round?: Keyword.get(overrides, :completed_working_round?, false),
      preceding_adversary_findings: [],
      events: [%{"from_role" => RoleProfiles.role_name(predecessor)}]
    }
  end

  defp reconstructed_transition(lifecycle_id, role, outcome, to_role, round, planning_attempt) do
    result = valid_result(role, outcome)

    %{
      "schema" => LifecycleHistory.schema(),
      "kind" => "transition",
      "lifecycle_id" => lifecycle_id,
      "role_result_schema" => result["schema"],
      "transition_id" =>
        LifecycleHistory.transition_id(
          lifecycle_id,
          round,
          planning_attempt,
          String.downcase(role) |> String.to_atom(),
          outcome
        ),
      "role" => role,
      "from_role" => role,
      "outcome" => outcome,
      "to_role" => to_role,
      "round" => round,
      "planning_attempt" => planning_attempt,
      "summary" => result["summary"],
      "evidence" => result["evidence"],
      "findings" => result["findings"],
      "human_question" => nil,
      "terminal_reason" => nil
    }
  end
end
