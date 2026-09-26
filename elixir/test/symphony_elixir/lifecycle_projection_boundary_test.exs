defmodule SymphonyElixir.LifecycleProjectionBoundaryTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Lifecycle, LifecycleCoordinator, LifecycleHistory, PromptBuilder}

  @host_only_planning_fields [
    :planning_cycle,
    :planning_cycle_start_attempt,
    :planning_cycle_attempt,
    :planning_guidance
  ]

  @planning_field_names Enum.map(@host_only_planning_fields, &Atom.to_string/1)

  test "fresh initial PM history keeps host coordinates but exposes none in projections or prompt" do
    lifecycle_id = "projection-initial-pm"
    assert {:ok, history} = LifecycleHistory.project([LifecycleHistory.start_event(lifecycle_id)])

    assert {
             history.planning_cycle,
             history.planning_cycle_start_attempt,
             history.planning_cycle_attempt,
             history.planning_guidance
           } == {0, 0, 0, nil}

    lifecycle_context = Lifecycle.lifecycle_context(history)
    handoff = LifecycleCoordinator.dispatch_handoff(history)

    assert history.current_role == :pm
    assert history.pm_phase == :initial
    refute Enum.any?(@host_only_planning_fields, &Map.has_key?(lifecycle_context, &1))
    refute Enum.any?(@host_only_planning_fields, &Map.has_key?(handoff, &1))

    prompt = build_prompt(:pm, lifecycle_context, handoff)
    Enum.each(@planning_field_names, &refute(prompt =~ &1))
    refute prompt =~ "planning cycle"
  end

  test "initial PM plan starts host cycle one and Reviewer revisions advance global and local attempts" do
    lifecycle_id = "projection-planning-attempts"
    start = LifecycleHistory.start_event(lifecycle_id)
    initial_plan = transition_event(lifecycle_id, "PM", "plan", "PLANNER", 1, 1)

    assert {:ok, first_planner} = LifecycleHistory.project([start, initial_plan])
    assert {first_planner.current_role, first_planner.pm_phase} == {:planner, :returning}

    assert {
             first_planner.planning_cycle,
             first_planner.planning_cycle_start_attempt,
             first_planner.planning_cycle_attempt,
             first_planner.planning_attempt
           } == {1, 1, 1, 1}

    first_planner_context = Lifecycle.lifecycle_context(first_planner)
    first_planner_handoff = LifecycleCoordinator.dispatch_handoff(first_planner)
    refute Map.has_key?(first_planner_context, :planning_guidance)
    refute Map.has_key?(first_planner_handoff, :planning_guidance)

    Enum.each([:planning_cycle, :planning_cycle_start_attempt, :planning_cycle_attempt], fn key ->
      refute Map.has_key?(first_planner_context, key)
      refute Map.has_key?(first_planner_handoff, key)
    end)

    planner_one = transition_event(lifecycle_id, "PLANNER", "plan_ready", "REVIEWER", 1, 1)
    reviewer_one = transition_event(lifecycle_id, "REVIEWER", "revise", "PLANNER", 1, 1)
    assert {:ok, after_one} = LifecycleHistory.project([start, initial_plan, planner_one, reviewer_one])
    assert {after_one.planning_attempt, after_one.planning_cycle_attempt} == {2, 2}

    planner_two = transition_event(lifecycle_id, "PLANNER", "plan_ready", "REVIEWER", 1, 2)
    reviewer_two = transition_event(lifecycle_id, "REVIEWER", "revise", "PLANNER", 1, 2)

    assert {:ok, after_two} =
             LifecycleHistory.project([start, initial_plan, planner_one, reviewer_one, planner_two, reviewer_two])

    assert {after_two.planning_attempt, after_two.planning_cycle_attempt} == {3, 3}

    planner_three = transition_event(lifecycle_id, "PLANNER", "plan_ready", "REVIEWER", 1, 3)

    reviewer_three =
      transition_event(lifecycle_id, "REVIEWER", "revise", "NON_CONVERGED", 1, 3)
      |> Map.merge(%{
        "kind" => "terminal",
        "terminal_reason" => "planning_attempt_exhausted",
        "findings" => [%{"severity" => "blocking", "summary" => "Resolve the reviewed defect.", "evidence" => ["review evidence"]}]
      })

    exhausted_events = [
      start,
      initial_plan,
      planner_one,
      reviewer_one,
      planner_two,
      reviewer_two,
      planner_three,
      reviewer_three
    ]

    assert {:ok, exhausted} = LifecycleHistory.project(exhausted_events)
    assert {exhausted.planning_attempt, exhausted.planning_cycle, exhausted.planning_cycle_attempt} == {3, 1, 3}
    assert {exhausted.current_role, exhausted.terminal} == {:reviewer, "non_converged"}
    refute exhausted.active?

    planning_response = %{
      "schema" => LifecycleHistory.schema(),
      "kind" => "planning_response_accepted",
      "lifecycle_id" => lifecycle_id,
      "transition_id" => "#{lifecycle_id}:r1:cycle2:planning_response",
      "boundary_transition_id" => reviewer_three["transition_id"],
      "round" => 1,
      "planning_cycle" => 2,
      "starting_planning_attempt" => 4,
      "guidance" => %{
        "decision" => "continue",
        "text" => "Correct the reviewed defect.",
        "authorized_actions" => [],
        "provenance" => %{"comment_id" => 812, "author_id" => 91}
      }
    }

    assert {:ok, resumed} = LifecycleHistory.project(exhausted_events ++ [planning_response])
    assert {resumed.lifecycle_id, resumed.epoch, resumed.round, resumed.epoch_round} == {lifecycle_id, 0, 1, 1}

    assert {
             resumed.planning_cycle,
             resumed.planning_cycle_start_attempt,
             resumed.planning_cycle_attempt,
             resumed.planning_attempt
           } == {2, 4, 1, 4}

    assert resumed.current_role == :planner
    assert List.last(resumed.events)["kind"] == "planning_response_accepted"
  end

  test "accepted continuation guidance and revision evidence reach only the resumed Planner" do
    {resumed, _planning_response} = resumed_planner_history()
    handoff = LifecycleCoordinator.dispatch_handoff(resumed)
    lifecycle_context = Lifecycle.lifecycle_context(resumed)

    assert handoff.planning_guidance["text"] == "Correct the reviewed defect."
    assert lifecycle_context.planning_guidance["text"] == "Correct the reviewed defect."

    assert handoff.revision_reconciliation.rejected_planner["transition_id"] ==
             LifecycleHistory.transition_id(resumed.lifecycle_id, resumed.round, 3, :planner, "plan_ready")

    reviewer_transition_id = LifecycleHistory.transition_id(resumed.lifecycle_id, resumed.round, 3, :reviewer, "revise")
    assert handoff.revision_reconciliation.reviewer["transition_id"] == reviewer_transition_id

    assert hd(handoff.revision_reconciliation.reviewer_findings)["finding"]["summary"] ==
             "Resolve the reviewed defect."

    planner_prompt = build_prompt(:planner, lifecycle_context, handoff)
    assert planner_prompt =~ "Host-accepted human planning guidance"
    assert planner_prompt =~ "Correct the reviewed defect."
    assert planner_prompt =~ "human_guidance_acknowledgment"
    assert planner_prompt =~ "Planner revision reconciliation"
    assert planner_prompt =~ "Resolve the reviewed defect."

    other_roles = [:pm, :reviewer, :implementer, :adversary, :archivist]

    for role <- other_roles do
      role_history = Map.put(resumed, :current_role, role)
      role_context = Lifecycle.lifecycle_context(role_history)
      role_handoff = LifecycleCoordinator.dispatch_handoff(role_history)
      prompt = build_prompt(role, role_context, role_handoff)

      refute Map.has_key?(role_context, :planning_guidance)
      refute Map.has_key?(role_handoff, :planning_guidance)
      refute prompt =~ "planning_guidance"
      refute prompt =~ "Host-accepted human planning guidance"
      Enum.each([:planning_cycle, :planning_cycle_start_attempt, :planning_cycle_attempt], &refute(Map.has_key?(role_context, &1)))
      Enum.each([:planning_cycle, :planning_cycle_start_attempt, :planning_cycle_attempt], &refute(Map.has_key?(role_handoff, &1)))
    end
  end

  test "planning and specialist guidance compose for a resumed Planner" do
    {history, _response} = resumed_planner_history()

    history =
      %{
        history
        | specialist_guidance: %{
            "response_transition_id" => "projection-resumed-planner:r1:p4:PLANNER:await_human:response",
            "text" => "Use the accepted bounded answer while revising the plan.",
            "authorized_actions" => [],
            "role" => "PLANNER"
          }
      }

    context = Lifecycle.lifecycle_context(history)
    handoff = LifecycleCoordinator.dispatch_handoff(history)
    prompt = build_prompt(:planner, context, handoff)

    assert context.planning_guidance["text"] == "Correct the reviewed defect."
    assert context.specialist_guidance["response_transition_id"] == history.specialist_guidance["response_transition_id"]
    assert handoff.planning_guidance["text"] == "Correct the reviewed defect."
    assert handoff.specialist_guidance["text"] == "Use the accepted bounded answer while revising the plan."
    assert prompt =~ "Host-accepted human planning guidance"
    assert prompt =~ "Host-accepted guidance for continuation of this role's prior await_human"
    assert prompt =~ history.specialist_guidance["response_transition_id"]
  end

  defp resumed_planner_history do
    lifecycle_id = "projection-resumed-planner"
    start = LifecycleHistory.start_event(lifecycle_id)
    initial_plan = transition_event(lifecycle_id, "PM", "plan", "PLANNER", 1, 1)

    cycle_events =
      Enum.flat_map(1..3, fn attempt ->
        planner = transition_event(lifecycle_id, "PLANNER", "plan_ready", "REVIEWER", 1, attempt)

        reviewer =
          transition_event(
            lifecycle_id,
            "REVIEWER",
            "revise",
            if(attempt == 3, do: "NON_CONVERGED", else: "PLANNER"),
            1,
            attempt
          )
          |> Map.put("findings", [
            %{"severity" => "blocking", "summary" => "Resolve the reviewed defect.", "evidence" => ["review evidence"]}
          ])

        if attempt == 3 do
          [planner, Map.merge(reviewer, %{"kind" => "terminal", "terminal_reason" => "planning_attempt_exhausted"})]
        else
          [planner, reviewer]
        end
      end)

    boundary = List.last(cycle_events)

    response = %{
      "schema" => LifecycleHistory.schema(),
      "kind" => "planning_response_accepted",
      "lifecycle_id" => lifecycle_id,
      "transition_id" => "#{lifecycle_id}:r1:cycle2:planning_response",
      "boundary_transition_id" => boundary["transition_id"],
      "round" => 1,
      "planning_cycle" => 2,
      "starting_planning_attempt" => 4,
      "guidance" => %{
        "decision" => "continue",
        "text" => "Correct the reviewed defect.",
        "authorized_actions" => [],
        "provenance" => %{"comment_id" => 812, "author_id" => 91}
      }
    }

    assert {:ok, history} = LifecycleHistory.project([start, initial_plan] ++ cycle_events ++ [response])
    {history, response}
  end

  defp build_prompt(role, lifecycle_context, handoff) do
    PromptBuilder.build_prompt(
      %Issue{identifier: "GH-8", title: "Projection boundary", description: "Synthetic lifecycle fixture."},
      role,
      %{lifecycle_context: lifecycle_context, handoff: handoff}
    )
  end

  defp transition_event(lifecycle_id, from_role, outcome, to_role, round, planning_attempt) do
    role = String.downcase(from_role) |> String.to_atom()

    %{
      "schema" => LifecycleHistory.schema(),
      "kind" => "transition",
      "lifecycle_id" => lifecycle_id,
      "role_result_schema" => "symphony.role-result/v1",
      "transition_id" => LifecycleHistory.transition_id(lifecycle_id, round, planning_attempt, role, outcome),
      "role" => from_role,
      "from_role" => from_role,
      "outcome" => outcome,
      "to_role" => to_role,
      "round" => round,
      "planning_attempt" => planning_attempt,
      "summary" => "bounded result",
      "evidence" => ["evidence"],
      "findings" => [],
      "human_question" => nil,
      "terminal_reason" => nil
    }
  end
end
