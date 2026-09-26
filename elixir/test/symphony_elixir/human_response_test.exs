defmodule SymphonyElixir.HumanResponseTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.HumanResponse

  @lifecycle "life-human"
  @escalation "life-human:r8:p1:PM:await_human"

  test "accepts only the configured authenticated numeric author" do
    comment = comment(42, 7001, guidance: "Continue with the measured correction.")

    assert {:ok, response} = HumanResponse.find([comment], @lifecycle, "epoch", @escalation, [7001])
    assert response["guidance"] == "Continue with the measured correction."
    assert response[:provenance]["comment_id"] == 42
    assert response[:provenance]["author_id"] == 7001
    assert response[:provenance]["content_digest"]
  end

  test "accepts specialist scope and rejects a response for a different specialist boundary" do
    specialist_escalation = "life-human:r8:p1:PLANNER:await_human"

    response_comment =
      comment(57, 7001, guidance: "Answer the exact planning question.", scope: "specialist")
      |> Map.put("body", body(@lifecycle, specialist_escalation, "Answer the exact planning question.", [], "specialist"))

    assert {:ok, response} =
             HumanResponse.find([response_comment], @lifecycle, "specialist", specialist_escalation, [7001])

    assert response["scope"] == "specialist"
    assert response["authorized_actions"] == []
    assert response[:provenance]["comment_id"] == 57

    stale =
      Map.put(
        response_comment,
        "body",
        body(@lifecycle, "life-human:r8:p1:REVIEWER:await_human", "stale", [], "specialist")
      )

    assert {:error, :stale_human_response_target} =
             HumanResponse.find([stale], @lifecycle, "specialist", specialist_escalation, [7001])
  end

  test "does not trust comment text or an unauthorized author" do
    body = body(@lifecycle, @escalation, "authorized-looking text")

    forged = %{
      "id" => 44,
      "body" => body,
      "user" => %{"id" => 9999, "login" => "duck-lint"},
      "created_at" => "2026-09-20T12:00:00Z",
      "updated_at" => "2026-09-20T12:00:00Z",
      "html_url" => "https://github.test/comment/44"
    }

    assert {:error, :unauthorized_human_response} =
             HumanResponse.find([forged], @lifecycle, "epoch", @escalation, [7001])
  end

  test "rejects edited comments, conflicting responses, and malformed response bodies" do
    edited = comment(45, 7001, updated_at: "2026-09-20T12:01:00Z")

    assert {:error, {:invalid_human_response, :edited_human_response_not_authorization}} =
             HumanResponse.find([edited], @lifecycle, "epoch", @escalation, [7001])

    first = comment(46, 7001, guidance: "First guidance")
    second = comment(47, 7001, guidance: "Conflicting guidance")

    assert {:error, :conflicting_human_responses} =
             HumanResponse.find([first, second], @lifecycle, "epoch", @escalation, [7001])

    malformed = Map.put(first, "body", "<!-- symphony.human-response/v1\nnot-json\n-->")

    assert {:error, {:invalid_human_response, %Jason.DecodeError{}}} =
             HumanResponse.find([malformed], @lifecycle, "epoch", @escalation, [7001])
  end

  test "preserves explicit action authorization separately from guidance" do
    comment = comment(48, 7001, guidance: "Proceed only with inspection.", authorized_actions: ["inspect"])

    assert {:ok, response} = HumanResponse.find([comment], @lifecycle, "epoch", @escalation, [7001])
    assert response["authorized_actions"] == ["inspect"]
    assert response["decision"] == "continue"
  end

  test "ignores comments without a body and non-map comments" do
    assert :ignore = HumanResponse.parse(%{"id" => 1}, 0)
    assert :ignore = HumanResponse.parse(:not_a_comment, 0)
    assert :none = HumanResponse.find([], @lifecycle, "epoch", @escalation, [7001])
  end

  test "rejects non-map payloads, invalid actions, and missing authors" do
    array_payload = "<!-- symphony.human-response/v1\n[]\n-->"

    assert {:error, {:invalid_human_response, :human_response_not_a_map}} =
             HumanResponse.find([Map.put(comment(49, 7001, []), "body", array_payload)], @lifecycle, "epoch", @escalation, [7001])

    unknown_field =
      comment(54, 7001, [])
      |> Map.put("body", body_with_extra_field(@lifecycle, @escalation))

    assert {:error, {:invalid_human_response, :unknown_human_response_fields}} =
             HumanResponse.find([unknown_field], @lifecycle, "epoch", @escalation, [7001])

    invalid_actions = comment(50, 7001, authorized_actions: ["", 42])

    assert {:error, {:invalid_human_response, :invalid_human_response_authorized_actions}} =
             HumanResponse.find([invalid_actions], @lifecycle, "epoch", @escalation, [7001])

    missing_actions = comment(55, 7001, [])
    missing_actions = Map.put(missing_actions, "body", body_without_actions(@lifecycle, @escalation))

    assert {:error, {:invalid_human_response, :invalid_human_response_authorized_actions}} =
             HumanResponse.find([missing_actions], @lifecycle, "epoch", @escalation, [7001])

    missing_author = Map.put(comment(51, 7001, []), "user", %{"login" => "configured-user"})

    assert {:error, {:invalid_human_response, :missing_human_response_author_id}} =
             HumanResponse.find([missing_author], @lifecycle, "epoch", @escalation, [7001])

    missing_comment_id = Map.delete(comment(56, 7001, []), "id")

    assert {:error, {:invalid_human_response, :missing_human_response_comment_id}} =
             HumanResponse.find([missing_comment_id], @lifecycle, "epoch", @escalation, [7001])

    atom_author = comment(52, 7001, []) |> Map.put("user", %{id: 7001, login: "configured-user"})
    assert {:ok, _response} = HumanResponse.find([atom_author], @lifecycle, "epoch", @escalation, [7001])
  end

  test "rejects a response for a stale escalation" do
    stale = comment(53, 7001, []) |> Map.put("body", body(@lifecycle, "old-escalation", "old guidance"))

    assert {:error, :stale_human_response_target} =
             HumanResponse.find([stale], @lifecycle, "epoch", @escalation, [7001])
  end

  defp comment(id, author_id, opts) do
    guidance = Keyword.get(opts, :guidance, "Continue.")
    updated_at = Keyword.get(opts, :updated_at, "2026-09-20T12:00:00Z")
    body = body(@lifecycle, @escalation, guidance, Keyword.get(opts, :authorized_actions, []), Keyword.get(opts, :scope, "epoch"))

    %{
      "id" => id,
      "body" => body,
      "user" => %{"id" => author_id, "login" => "configured-user"},
      "created_at" => "2026-09-20T12:00:00Z",
      "updated_at" => updated_at,
      "html_url" => "https://github.test/comment/#{id}"
    }
  end

  defp body(lifecycle_id, escalation_id, guidance, authorized_actions \\ [], scope \\ "epoch") do
    "<!-- symphony.human-response/v1\n" <>
      Jason.encode!(
        %{
          "schema" => HumanResponse.schema(),
          "lifecycle_id" => lifecycle_id,
          "scope" => scope,
          "target_transition_id" => escalation_id,
          "decision" => "continue",
          "guidance" => guidance,
          "authorized_actions" => authorized_actions
        },
        pretty: true
      ) <>
      "\n-->\n"
  end

  defp body_without_actions(lifecycle_id, escalation_id) do
    "<!-- symphony.human-response/v1\n" <>
      Jason.encode!(%{
        "schema" => HumanResponse.schema(),
        "lifecycle_id" => lifecycle_id,
        "scope" => "epoch",
        "target_transition_id" => escalation_id,
        "decision" => "continue",
        "guidance" => "Continue."
      }) <>
      "\n-->\n"
  end

  defp body_with_extra_field(lifecycle_id, escalation_id) do
    "<!-- symphony.human-response/v1\n" <>
      Jason.encode!(%{
        "schema" => HumanResponse.schema(),
        "lifecycle_id" => lifecycle_id,
        "scope" => "epoch",
        "target_transition_id" => escalation_id,
        "decision" => "continue",
        "guidance" => "Continue.",
        "authorized_actions" => [],
        "extra" => true
      }) <>
      "\n-->\n"
  end
end
