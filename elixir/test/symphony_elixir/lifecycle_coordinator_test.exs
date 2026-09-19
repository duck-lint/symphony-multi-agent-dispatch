defmodule SymphonyElixir.LifecycleCoordinatorTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{LifecycleCoordinator, LifecycleHistory}

  defmodule FakeGitHubClient do
    def fetch_issue(_issue_id), do: {:ok, Agent.get(state(), & &1.issue)}
    def fetch_issue_comments(_issue_id), do: {:ok, Agent.get(state(), & &1.comments)}

    def append_issue_comment(_issue_id, body) do
      Agent.get_and_update(state(), fn current ->
        comment = %{"body" => body}
        {{:ok, comment}, %{current | comments: current.comments ++ [comment], trace: current.trace ++ [{:append, body}]}}
      end)
    end

    def add_issue_label(_issue_id, label) do
      Agent.get_and_update(state(), fn current ->
        labels = Enum.uniq(current.issue.labels ++ [String.downcase(label)])
        issue = %{current.issue | labels: labels}
        {{:ok, labels}, %{current | issue: issue, trace: current.trace ++ [{:add, label}]}}
      end)
    end

    def remove_issue_label(_issue_id, label) do
      Agent.get_and_update(state(), fn current ->
        labels = Enum.reject(current.issue.labels, &(String.downcase(&1) == String.downcase(label)))
        issue = %{current.issue | labels: labels}
        {{:ok, labels}, %{current | issue: issue, trace: current.trace ++ [{:remove, label}]}}
      end)
    end

    defp state, do: Application.fetch_env!(:symphony_elixir, :lifecycle_fake_github_state)
  end

  setup do
    {:ok, agent} = Agent.start_link(fn -> %{issue: github_issue(), comments: [], trace: []} end)
    previous_client = Application.get_env(:symphony_elixir, :github_client_module)
    Application.put_env(:symphony_elixir, :lifecycle_fake_github_state, agent)
    Application.delete_env(:symphony_elixir, :github_client_module)
    File.write!(InstanceConfig.instance_config_file_path(), github_config())
    assert :ok = InstanceConfigStore.force_reload()
    Application.put_env(:symphony_elixir, :github_client_module, FakeGitHubClient)

    on_exit(fn ->
      if is_nil(previous_client) do
        Application.delete_env(:symphony_elixir, :github_client_module)
      else
        Application.put_env(:symphony_elixir, :github_client_module, previous_client)
      end

      Application.delete_env(:symphony_elixir, :lifecycle_fake_github_state)
      if Process.alive?(agent), do: Agent.stop(agent)
    end)

    :ok
  end

  test "initializes, commits, and idempotently replays a PM transition" do
    issue = github_issue()

    assert {:ok, %{history: %{lifecycle_id: lifecycle_id}, lifecycle_context: initial_context}} =
             LifecycleCoordinator.prepare_dispatch(issue)

    assert initial_context.current_role == "PM"
    assert initial_context.lifecycle_position == "initial_pm"

    result = role_result("PM", "plan", "Plan accepted intent")

    assert {:ok, %{idempotent?: false, event: event, issue: projected}} =
             LifecycleCoordinator.commit_role_result(issue, :pm, result)

    assert event["kind"] == "transition"
    assert event["role"] == "PM"
    assert event["role_result_schema"] == "symphony.role-result/v1"
    assert event["to_role"] == "PLANNER"
    assert event["lifecycle_id"] == lifecycle_id
    assert event["human_question"] == nil
    assert event["terminal_reason"] == nil
    assert projected.labels == ["symphony:auto", "human-label", "symphony:role:planner"]

    assert {:ok, %{idempotent?: true}} =
             LifecycleCoordinator.commit_role_result(issue, :pm, result)

    state = Agent.get(Application.fetch_env!(:symphony_elixir, :lifecycle_fake_github_state), & &1)
    assert Enum.count(state.comments, &String.contains?(&1["body"], "symphony.lifecycle/v1")) == 2
    assert Enum.all?(state.comments, &(not String.contains?(&1["body"], "<!--")))

    transition_append_index =
      Enum.find_index(state.trace, fn
        {:append, body} -> String.contains?(body, "\"kind\": \"transition\"")
        _ -> false
      end)

    first_projection_mutation_index =
      state.trace
      |> Enum.with_index()
      |> Enum.find_value(fn
        {{:remove, "symphony:role:pm"}, index} when index > transition_append_index -> index
        _ -> nil
      end)

    assert transition_append_index < first_projection_mutation_index

    assert {:ok, %{history: planner_history, lifecycle_context: first_planner_context}} =
             LifecycleCoordinator.prepare_dispatch(projected)

    assert planner_history.current_role == :planner
    assert first_planner_context.current_role == "PLANNER"
    assert first_planner_context.predecessor == "PM"

    assert {:ok, %{lifecycle_context: second_planner_context}} =
             LifecycleCoordinator.prepare_dispatch(projected)

    assert first_planner_context == second_planner_context
  end

  test "Reviewer revision dispatch carries the exact Planner and Reviewer evidence pair" do
    lifecycle_id = "planner-revision"
    install_planner_revision_history(planner_revision_events(lifecycle_id))

    assert {:ok, %{history: history, handoff: handoff}} =
             LifecycleCoordinator.prepare_dispatch(github_issue())

    assert history.current_role == :planner
    projection = handoff.revision_reconciliation
    [planner_event, reviewer_event] = Enum.take([Enum.at(history.events, -2), Enum.at(history.events, -1)], 2)

    assert projection.rejected_planner["transition_id"] == planner_event["transition_id"]
    assert projection.rejected_planner["summary"] == planner_event["summary"]
    assert projection.rejected_planner["evidence"] == planner_event["evidence"]
    assert projection.reviewer["transition_id"] == reviewer_event["transition_id"]
    assert projection.reviewer["findings"] == reviewer_event["findings"]
    assert Enum.map(projection.reviewer_findings, & &1["finding_ref"]) ==
             Enum.with_index(reviewer_event["findings"])
             |> Enum.map(fn {_finding, index} -> "#{reviewer_event["transition_id"]}:finding:#{index}" end)
  end

  test "revised Planner cannot commit without complete host reconciliation" do
    lifecycle_id = "planner-revision-missing"
    install_planner_revision_history(planner_revision_events(lifecycle_id))
    assert {:ok, %{handoff: %{revision_reconciliation: projection}}} =
             LifecycleCoordinator.prepare_dispatch(github_issue())

    result = planner_revision_result(projection, "Install with the exact command and verify independently.")
    state_before = Agent.get(Application.fetch_env!(:symphony_elixir, :lifecycle_fake_github_state), & &1)

    assert {:error, :missing_returning_planner_revision_reconciliation} =
             LifecycleCoordinator.commit_role_result(github_issue(), :planner, Map.delete(result, "revision_reconciliation"))

    state_after = Agent.get(Application.fetch_env!(:symphony_elixir, :lifecycle_fake_github_state), & &1)
    assert state_after.comments == state_before.comments
    assert {:ok, %{history: history}} = LifecycleCoordinator.prepare_dispatch(github_issue())
    assert history.planning_attempt == 1
    assert LifecycleCoordinator.correctable_role_result_error?(:missing_returning_planner_revision_reconciliation)
  end

  test "revised Planner rejects stale, duplicate, fabricated, and invalid excerpt references" do
    lifecycle_id = "planner-revision-invalid"
    install_planner_revision_history(planner_revision_events(lifecycle_id))
    assert {:ok, %{handoff: %{revision_reconciliation: projection}}} =
             LifecycleCoordinator.prepare_dispatch(github_issue())

    valid = planner_revision_result(projection, "Install exact command. Verify independently.")
    refs = Enum.map(projection.reviewer_findings, & &1["finding_ref"])

    invalid_results = [
      put_in(valid, ["revision_reconciliation", "finding_responses"],
        List.replace_at(valid["revision_reconciliation"]["finding_responses"], 1, %{
          "finding_ref" => List.first(refs),
          "assessment" => "duplicate",
          "plan_excerpt" => "Verify independently."
        })),
      put_in(valid, ["revision_reconciliation", "finding_responses"],
        List.replace_at(valid["revision_reconciliation"]["finding_responses"], 0, %{
          "finding_ref" => "other-review:finding:0",
          "assessment" => "fabricated",
          "plan_excerpt" => "Install exact command."
        })),
      put_in(valid, ["revision_reconciliation", "reviewer_transition_id"], "stale-reviewer"),
      put_in(valid, ["revision_reconciliation", "finding_responses", Access.at(0), "plan_excerpt"], "not in plan")
    ]

    for invalid <- invalid_results do
      assert {:error, _reason} = LifecycleCoordinator.commit_role_result(github_issue(), :planner, invalid)
    end

    assert {:ok, %{history: history}} = LifecycleCoordinator.prepare_dispatch(github_issue())
    assert history.planning_attempt == 1
    assert length(history.events) == length(planner_revision_events(lifecycle_id))
  end

  test "complete Planner reconciliation persists, replays, and reaches Reviewer without semantic approval" do
    lifecycle_id = "planner-revision-valid"
    install_planner_revision_history(planner_revision_events(lifecycle_id))
    assert {:ok, %{handoff: %{revision_reconciliation: projection}}} =
             LifecycleCoordinator.prepare_dispatch(github_issue())

    # The summary is structurally valid even though it remains substantively generic;
    # the next Reviewer, not this host check, judges whether the correction is adequate.
    result = planner_revision_result(projection, "Install exact command. Verify independently.")

    assert {:ok, %{event: event, idempotent?: false, issue: issue}} =
             LifecycleCoordinator.commit_role_result(github_issue(), :planner, result)

    assert event["revision_reconciliation"] == result["revision_reconciliation"]
    assert issue.labels == ["symphony:auto", "human-label", "symphony:role:reviewer"]

    assert {:ok, %{history: history}} = LifecycleCoordinator.prepare_dispatch(issue)
    assert List.last(history.events)["revision_reconciliation"] == result["revision_reconciliation"]

    assert {:ok, %{idempotent?: true}} =
             LifecycleCoordinator.commit_role_result(github_issue(), :planner, result)
  end

  test "Planner await_human revision accounting does not bypass prerequisite authority" do
    lifecycle_id = "planner-revision-await"
    install_planner_revision_history(planner_revision_events(lifecycle_id))
    assert {:ok, %{handoff: %{revision_reconciliation: projection}}} =
             LifecycleCoordinator.prepare_dispatch(github_issue())

    result =
      planner_revision_result(projection, "The external prerequisite cannot be supplied by this role.")
      |> Map.merge(%{
        "outcome" => "await_human",
        "human_question" => "Authorize the required external capability.",
        "prerequisite_resolution" => external_prerequisite_report(),
        "revision_reconciliation" => nil_excerpt_revision_reconciliation(projection)
      })

    assert {:ok, %{event: event}} =
             LifecycleCoordinator.commit_role_result(github_issue(), :planner, result)

    assert event["kind"] == "escalation"
    assert event["revision_reconciliation"] == result["revision_reconciliation"]
  end

  test "Planner non_converged revision accounting still requires complete prerequisite investigation" do
    lifecycle_id = "planner-revision-non-converged"
    install_planner_revision_history(planner_revision_events(lifecycle_id))
    assert {:ok, %{handoff: %{revision_reconciliation: projection}}} =
             LifecycleCoordinator.prepare_dispatch(github_issue())

    result =
      planner_revision_result(projection, "No feasible authorized path has been established.")
      |> Map.merge(%{
        "outcome" => "non_converged",
        "prerequisite_resolution" => prerequisite_report(),
        "revision_reconciliation" => nil_excerpt_revision_reconciliation(projection)
      })

    assert {:ok, %{event: event}} =
             LifecycleCoordinator.commit_role_result(github_issue(), :planner, result)

    assert event["kind"] == "terminal"
    assert event["terminal_reason"] == "prerequisite_no_feasible_authorized_path"
  end

  test "reconciles Normalize issue #5 evidence without substituting either report" do
    lifecycle_id = "normalize-5"
    events = issue_five_round_events(lifecycle_id)
    install_returning_pm_history(events)

    assert {:ok, %{handoff: handoff}} = LifecycleCoordinator.prepare_dispatch(github_issue())
    reconciliation = handoff.reconciliation

    assert Enum.map(reconciliation.accepted_events, & &1["role"]) == [
             "PLANNER",
             "REVIEWER",
             "IMPLEMENTER",
             "ADVERSARY"
           ]

    assert Enum.find(reconciliation.accepted_events, &(&1["role"] == "IMPLEMENTER"))["evidence"] == [
             "TMPDIR=/tmp .venv/bin/pytest -q -s reportedly yielded 12 passed",
             "clean-wheel verification reportedly succeeded"
           ]

    assert Enum.find(reconciliation.accepted_events, &(&1["role"] == "ADVERSARY"))["evidence"] == [
             "separate pytest invocation yielded six passed",
             "six temporary-directory setup errors occurred before affected assertions"
           ]

    adversary_only =
      role_result("PM", "plan", "The reports require another authorized working round.")
      |> Map.put("reconciliation", %{
        "considered_transition_ids" => [
          LifecycleHistory.transition_id(lifecycle_id, 1, 1, :adversary, "review_complete")
        ],
        "assessment" => "The independent run did not reproduce complete acceptance."
      })

    assert {:error, {:invalid_reconciliation_reference, _}} =
             LifecycleCoordinator.commit_role_result(github_issue(), :pm, adversary_only)

    valid = Map.put(adversary_only, "reconciliation", reconciliation_payload(reconciliation))

    assert {:ok, %{event: event, idempotent?: false}} =
             LifecycleCoordinator.commit_role_result(github_issue(), :pm, valid)

    assert event["reconciliation"] == valid["reconciliation"]
    assert event["to_role"] == "PLANNER"

    assert {:ok, %{history: restarted_history}} = LifecycleCoordinator.prepare_dispatch(github_issue())
    assert List.last(restarted_history.events)["reconciliation"] == valid["reconciliation"]

    assert {:ok, %{idempotent?: true}} =
             LifecycleCoordinator.commit_role_result(github_issue(), :pm, valid)

    invalid_replay = Map.delete(valid, "reconciliation")

    assert {:error, :missing_returning_pm_reconciliation} =
             LifecycleCoordinator.commit_role_result(github_issue(), :pm, invalid_replay)
  end

  test "returning PM cannot omit, duplicate, fabricate, or use prior-round evidence" do
    lifecycle_id = "normalize-5-references"
    install_returning_pm_history(issue_five_round_events(lifecycle_id))

    assert {:ok, %{handoff: %{reconciliation: projection}}} =
             LifecycleCoordinator.prepare_dispatch(github_issue())

    ids = projection.required_transition_ids
    implementer_id = LifecycleHistory.transition_id(lifecycle_id, 1, 1, :implementer, "implementation_complete")
    adversary_id = LifecycleHistory.transition_id(lifecycle_id, 1, 1, :adversary, "review_complete")
    valid_base = role_result("PM", "plan", "Another authorized working round is required.")

    for bad_ids <- [
          List.delete(ids, implementer_id),
          List.delete(ids, adversary_id),
          ids ++ [List.first(ids)],
          List.replace_at(ids, 0, "other-life:r1:p1:IMPLEMENTER:implementation_complete"),
          List.replace_at(ids, 0, LifecycleHistory.transition_id(lifecycle_id, 0, 0, :pm, "plan"))
        ] do
      result =
        Map.put(valid_base, "reconciliation", %{
          "considered_transition_ids" => bad_ids,
          "assessment" => "The current reports were considered."
        })

      assert {:error, _reason} =
               LifecycleCoordinator.commit_role_result(github_issue(), :pm, result)
    end
  end

  test "returning PM escalation requires external basis and accepted evidence" do
    lifecycle_id = "normalize-5-escalation"
    events = issue_five_round_events(lifecycle_id)
    install_returning_pm_history(events)

    # The real projection is taken from current authoritative comments, not this
    # local value; this assertion also guards that the helper is not a second ledger.
    assert {:ok, %{handoff: %{reconciliation: projection}}} =
             LifecycleCoordinator.prepare_dispatch(github_issue())

    result =
      role_result("PM", "await_human", "An external authorization is required.")
      |> Map.put("reconciliation", reconciliation_payload(projection))
      |> Map.put("human_question", "Authorize access to the required external fixture.")
      |> Map.put("escalation_basis", %{
        "required_external_action" => "Authorize access to the required external fixture.",
        "existing_authority_gap" => "The current read-only project authority cannot supply it.",
        "supporting_transition_ids" => [
          LifecycleHistory.transition_id(lifecycle_id, 1, 1, :implementer, "implementation_complete"),
          LifecycleHistory.transition_id(lifecycle_id, 1, 1, :adversary, "review_complete")
        ]
      })

    assert {:ok, %{event: event}} =
             LifecycleCoordinator.commit_role_result(github_issue(), :pm, result)

    assert event["kind"] == "escalation"
    assert event["escalation_basis"] == result["escalation_basis"]
  end

  test "initial PM await_human without escalation basis is rejected without a transition" do
    assert {:ok, _} = LifecycleCoordinator.prepare_dispatch(github_issue())
    result = role_result("PM", "await_human", "A decision is required.")
    result = Map.put(result, "human_question", "What decision should be made?")

    assert {:error, :missing_pm_escalation_basis} =
             LifecycleCoordinator.commit_role_result(github_issue(), :pm, result)

    state = Agent.get(Application.fetch_env!(:symphony_elixir, :lifecycle_fake_github_state), & &1)
    assert length(state.comments) == 1
  end

  test "valid reconciliation preserves convergence routing and blocking findings still reject it" do
    lifecycle_id = "normalize-5-convergence"
    events = issue_five_round_events(lifecycle_id)
    install_returning_pm_history(events)

    assert {:ok, %{handoff: %{reconciliation: projection}}} =
             LifecycleCoordinator.prepare_dispatch(github_issue())

    converging_result =
      role_result("PM", "converge", "The objective is satisfied after reconciling both reports.")
      |> Map.put("reconciliation", reconciliation_payload(projection))

    assert {:ok, %{event: event}} =
             LifecycleCoordinator.commit_role_result(github_issue(), :pm, converging_result)

    assert event["to_role"] == "ARCHIVIST"

    blocking_events =
      issue_five_round_events("normalize-5-blocked")
      |> List.update_at(
        5,
        &Map.put(&1, "findings", [
          %{
            "severity" => "blocking",
            "summary" => "The adversarial result blocks convergence.",
            "evidence" => ["The blocking condition remains unresolved."]
          }
        ])
      )

    install_returning_pm_history(blocking_events)

    assert {:ok, %{handoff: %{reconciliation: blocked_projection}}} =
             LifecycleCoordinator.prepare_dispatch(github_issue())

    blocked_result = Map.put(converging_result, "reconciliation", reconciliation_payload(blocked_projection))

    assert {:error, :blocking_adversary_findings} =
             LifecycleCoordinator.commit_role_result(github_issue(), :pm, blocked_result)
  end

  test "a complete prerequisite investigation can produce a visible non-converged terminal" do
    lifecycle_id = "life-prerequisite"

    Agent.update(Application.fetch_env!(:symphony_elixir, :lifecycle_fake_github_state), fn state ->
      %{
        state
        | issue: %{state.issue | labels: ["symphony:auto", "symphony:role:planner", "human-label"]},
          comments: [
            %{"body" => LifecycleHistory.render(LifecycleHistory.start_event(lifecycle_id))},
            %{"body" => LifecycleHistory.render(transition_event(lifecycle_id, "PM", "plan", "PLANNER", 1, 1))}
          ]
      }
    end)

    result =
      role_result("PLANNER", "non_converged", "No feasible authorized path was established")
      |> Map.put("prerequisite_resolution", prerequisite_report())

    assert {:ok, %{event: event, history: history, idempotent?: false}} =
             LifecycleCoordinator.commit_role_result(github_issue(), :planner, result)

    assert event["kind"] == "terminal"
    assert event["terminal_reason"] == "prerequisite_no_feasible_authorized_path"
    assert event["prerequisite_resolution"] == result["prerequisite_resolution"]
    assert List.last(history.events) == event

    state = Agent.get(Application.fetch_env!(:symphony_elixir, :lifecycle_fake_github_state), & &1)
    assert "symphony:state:non-converged" in state.issue.labels
    refute "symphony:auto" in state.issue.labels

    assert {:ok, %{idempotent?: true}} =
             LifecycleCoordinator.commit_role_result(github_issue(), :planner, result)
  end

  test "does not dispatch an opted-out issue" do
    Agent.update(Application.fetch_env!(:symphony_elixir, :lifecycle_fake_github_state), fn state ->
      %{state | issue: %{state.issue | labels: ["symphony:role:pm"]}}
    end)

    assert {:error, :symphony_auto_required} = LifecycleCoordinator.prepare_dispatch(github_issue())
  end

  test "a destination label without its durable event is blocked" do
    Agent.update(Application.fetch_env!(:symphony_elixir, :lifecycle_fake_github_state), fn state ->
      %{
        state
        | issue: %{state.issue | labels: ["symphony:auto", "symphony:role:planner"]},
          comments: [
            %{"body" => LifecycleHistory.render(LifecycleHistory.start_event("life-1"))}
          ]
      }
    end)

    assert {:skip, {:blocked_lifecycle, _reason}} = LifecycleCoordinator.prepare_dispatch(github_issue())
    state = Agent.get(Application.fetch_env!(:symphony_elixir, :lifecycle_fake_github_state), & &1)
    assert "symphony:state:blocked" in state.issue.labels
    refute "symphony:auto" in state.issue.labels
  end

  test "an already-correct terminal projection is read-only" do
    Agent.update(Application.fetch_env!(:symphony_elixir, :lifecycle_fake_github_state), fn state ->
      %{
        state
        | issue: %{state.issue | labels: ["symphony:state:lifecycle-complete", "human-label"]},
          comments: terminal_lifecycle_comments()
      }
    end)

    assert {:skip, {:terminal_lifecycle, "lifecycle_complete"}} =
             LifecycleCoordinator.prepare_dispatch(github_issue())

    state = Agent.get(Application.fetch_env!(:symphony_elixir, :lifecycle_fake_github_state), & &1)
    assert state.trace == []
  end

  test "terminal projection drift is repaired" do
    Agent.update(Application.fetch_env!(:symphony_elixir, :lifecycle_fake_github_state), fn state ->
      %{
        state
        | issue: %{state.issue | labels: ["symphony:state:non-converged", "human-label"]},
          comments: terminal_lifecycle_comments()
      }
    end)

    assert {:skip, {:terminal_lifecycle, "lifecycle_complete"}} =
             LifecycleCoordinator.prepare_dispatch(github_issue())

    state = Agent.get(Application.fetch_env!(:symphony_elixir, :lifecycle_fake_github_state), & &1)

    assert state.trace == [
             {:remove, "symphony:state:non-converged"},
             {:add, "symphony:state:lifecycle-complete"}
           ]

    assert state.issue.labels == ["human-label", "symphony:state:lifecycle-complete"]
  end

  test "blocks PM continuity without consuming lifecycle state" do
    issue = github_issue()

    assert {:ok, projected} =
             LifecycleCoordinator.block_pm_continuity(issue, :required_thread_unavailable)

    assert projected.state == "open"
    assert projected.labels == ["symphony:role:pm", "human-label", "symphony:state:blocked"]

    state =
      Agent.get(
        Application.fetch_env!(:symphony_elixir, :lifecycle_fake_github_state),
        & &1
      )

    assert Enum.any?(state.comments, &String.contains?(&1["body"], "PM thread continuity blocked"))

    append_index =
      Enum.find_index(state.trace, fn
        {:append, body} -> String.contains?(body, "PM thread continuity blocked")
        _ -> false
      end)

    remove_auto_index = Enum.find_index(state.trace, &(&1 == {:remove, "symphony:auto"}))
    assert append_index < remove_auto_index
  end

  defp github_issue do
    %Issue{
      id: "42",
      identifier: "GH-42",
      title: "Lifecycle test",
      description: "Test issue",
      state: "open",
      url: "https://github.test/octo/repo/issues/42",
      labels: ["symphony:auto", "symphony:role:pm", "human-label"]
    }
  end

  defp github_config do
    """
    tracker:
      kind: github
      provider:
        repo: "octo/repo"
        token: "test-token"
      active_states: ["open"]
      terminal_states: ["closed"]
    polling:
      interval_ms: 30000
    workspace:
      root: "#{Path.join(System.tmp_dir!(), "symphony-lifecycle-test-workspaces")}"
    """
  end

  defp role_result(role, outcome, summary) do
    %{
      "schema" => "symphony.role-result/v1",
      "role" => role,
      "outcome" => outcome,
      "summary" => summary,
      "evidence" => ["host test evidence"],
      "findings" => []
    }
  end

  defp planner_revision_result(projection, summary) do
    responses =
      Enum.map(projection.reviewer_findings, fn finding ->
        excerpt =
          case finding["index"] do
            0 -> "Install exact command."
            1 -> "Verify independently."
          end

        %{
          "finding_ref" => finding["finding_ref"],
          "assessment" => "The finding is accounted for with evidence and an owned correction.",
          "plan_excerpt" => excerpt
        }
      end)

    role_result("PLANNER", "plan_ready", summary)
    |> Map.put("revision_reconciliation", %{
      "rejected_planner_transition_id" => projection.rejected_planner["transition_id"],
      "reviewer_transition_id" => projection.reviewer["transition_id"],
      "finding_responses" => responses
    })
  end

  defp nil_excerpt_revision_reconciliation(projection) do
    planner_revision_result(projection, "placeholder")["revision_reconciliation"]
    |> Map.update!("finding_responses", fn responses ->
      Enum.map(responses, &Map.put(&1, "plan_excerpt", nil))
    end)
  end

  defp install_planner_revision_history(events) do
    Agent.update(Application.fetch_env!(:symphony_elixir, :lifecycle_fake_github_state), fn state ->
      %{
        state
        | issue: %{state.issue | labels: ["symphony:auto", "symphony:role:planner", "human-label"]},
          comments: Enum.map(events, &%{"body" => LifecycleHistory.render(&1)})
      }
    end)
  end

  defp planner_revision_events(lifecycle_id) do
    reviewer =
      transition_event(lifecycle_id, "REVIEWER", "revise", "PLANNER", 1, 1)
      |> Map.merge(%{
        "summary" => "Require the exact installation command and independent console verification.",
        "evidence" => ["Reviewer inspected the contract and plan."],
        "findings" => [
          %{
            "severity" => "blocking",
            "summary" => "The exact installation command is absent.",
            "evidence" => ["The task requires the exact command to be named."]
          },
          %{
            "severity" => "advisory",
            "summary" => "Independent console verification is not assigned.",
            "evidence" => ["The acceptance contract requires a separate console check."]
          }
        ]
      })

    [
      LifecycleHistory.start_event(lifecycle_id),
      transition_event(lifecycle_id, "PM", "plan", "PLANNER", 1, 1),
      transition_event(lifecycle_id, "PLANNER", "plan_ready", "REVIEWER", 1, 1)
      |> Map.put("summary", "Original plan omits the exact command and independent verification."),
      reviewer
    ]
  end

  defp install_returning_pm_history(events) do
    Agent.update(Application.fetch_env!(:symphony_elixir, :lifecycle_fake_github_state), fn state ->
      %{
        state
        | issue: %{state.issue | labels: ["symphony:auto", "symphony:role:pm", "human-label"]},
          comments: Enum.map(events, &%{"body" => LifecycleHistory.render(&1)})
      }
    end)
  end

  defp reconciliation_payload(%{required_transition_ids: ids}),
    do: %{
      "considered_transition_ids" => ids,
      "assessment" => "The reports are both retained with distinct provenance; the independent run did not establish an application assertion failure."
    }

  defp issue_five_round_events(lifecycle_id) do
    [
      LifecycleHistory.start_event(lifecycle_id),
      transition_event(lifecycle_id, "PM", "plan", "PLANNER", 1, 1),
      transition_event(lifecycle_id, "PLANNER", "plan_ready", "REVIEWER", 1, 1),
      transition_event(lifecycle_id, "REVIEWER", "accept", "IMPLEMENTER", 1, 1),
      transition_event(lifecycle_id, "IMPLEMENTER", "implementation_complete", "ADVERSARY", 1, 1)
      |> Map.merge(%{
        "summary" => "Reported implementation verification completed.",
        "evidence" => [
          "TMPDIR=/tmp .venv/bin/pytest -q -s reportedly yielded 12 passed",
          "clean-wheel verification reportedly succeeded"
        ]
      }),
      transition_event(lifecycle_id, "ADVERSARY", "review_complete", "PM", 1, 1)
      |> Map.merge(%{
        "summary" => "Independent reproduction was incomplete because setup failed.",
        "evidence" => [
          "separate pytest invocation yielded six passed",
          "six temporary-directory setup errors occurred before affected assertions"
        ]
      })
    ]
  end

  defp prerequisite_report do
    %{
      "blocked_objective" => "Complete the authorized lifecycle change.",
      "missing_prerequisite" => "A required capability has not been established.",
      "absence_evidence" => ["The capability was not present in the inspected state."],
      "authoritative_requirement" => ["The governing task contract requires the capability."],
      "alternatives" => [
        %{
          "approach" => "Use the documented mechanism.",
          "evidence" => ["The mechanism was inspected and did not establish the prerequisite."],
          "disposition" => "demonstrated_infeasible"
        }
      ],
      "authority_status" => "not_resolvable_with_existing_authority",
      "unlock_action" => "Supply evidence or capability for the missing prerequisite.",
      "resolution_status" => "no_feasible_authorized_path_established"
    }
  end

  defp external_prerequisite_report do
    prerequisite_report()
    |> Map.merge(%{
      "authority_status" => "requires_external_action",
      "resolution_status" => "external_prerequisite"
    })
  end

  defp terminal_lifecycle_comments do
    lifecycle_id = "life-terminal"

    events = [
      LifecycleHistory.start_event(lifecycle_id),
      transition_event(lifecycle_id, "PM", "plan", "PLANNER", 1, 1),
      transition_event(lifecycle_id, "PLANNER", "plan_ready", "REVIEWER", 1, 1),
      transition_event(lifecycle_id, "REVIEWER", "accept", "IMPLEMENTER", 1, 1),
      transition_event(lifecycle_id, "IMPLEMENTER", "implementation_complete", "ADVERSARY", 1, 1),
      transition_event(lifecycle_id, "ADVERSARY", "review_complete", "PM", 1, 1),
      transition_event(lifecycle_id, "PM", "converge", "ARCHIVIST", 1, 1),
      terminal_event(lifecycle_id, "ARCHIVIST", "archive_complete", "LIFECYCLE_COMPLETE", 1, 1)
    ]

    Enum.map(events, &%{"body" => LifecycleHistory.render(&1)})
  end

  defp transition_event(lifecycle_id, from_role, outcome, to_role, round, planning_attempt) do
    %{
      "schema" => LifecycleHistory.schema(),
      "kind" => "transition",
      "lifecycle_id" => lifecycle_id,
      "role_result_schema" => "symphony.role-result/v1",
      "transition_id" =>
        LifecycleHistory.transition_id(
          lifecycle_id,
          round,
          planning_attempt,
          String.downcase(from_role) |> String.to_atom(),
          outcome
        ),
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

  defp terminal_event(lifecycle_id, from_role, outcome, to_role, round, planning_attempt) do
    transition_event(lifecycle_id, from_role, outcome, to_role, round, planning_attempt)
    |> Map.put("kind", "terminal")
  end
end
