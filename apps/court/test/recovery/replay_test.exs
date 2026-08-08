defmodule Court.Recovery.ReplayTest do
  use ExUnit.Case, async: false

  alias Court.{Artifacts, Error, RecoveryOracle, Replay}
  alias Court.Synthetic.Action

  defp context do
    %{
      actor: "owner",
      resident_id: Court.new_id(),
      incarnation_id: Court.new_id(),
      authority: "owner",
      reason: "M1 synthetic recovery test",
      retention_policy_version: 1
    }
  end

  test "pure replay derives unknown outcomes and all ruled artifact states" do
    recording = context()

    {:ok, available_ref} = Artifacts.publish("oracle available #{Court.new_id()}")
    {:ok, pending_ref} = Artifacts.publish("oracle pending #{Court.new_id()}")
    {:ok, tombstoned_ref} = Artifacts.publish("oracle tombstone #{Court.new_id()}")

    assert {:ok, unknown, _events} =
             Action.dispatched_unknown(recording,
               idempotency: :non_idempotent,
               artifact_refs: [available_ref, pending_ref, tombstoned_ref]
             )

    assert {:ok, pending_request} = Artifacts.delete_requested(pending_ref, recording)
    assert {:ok, tombstone_request} = Artifacts.delete_requested(tombstoned_ref, recording)
    assert {:ok, tombstone} = Artifacts.complete_deletion(tombstoned_ref, recording)

    assert {:ok, completed, _proposed} = Action.propose(recording, idempotency: :idempotent)
    assert {:ok, completed, _approved} = Action.approve(completed)
    assert {:ok, completed, _claimed} = Action.claim(completed)
    assert {:ok, completed, _dispatched} = Action.dispatch(completed)
    assert {:ok, completed, _succeeded} = Action.succeed(completed)

    maximum = Court.max_event_seq()
    assert {:ok, prefix} = Court.by_seq_range(1, maximum)
    assert {:ok, first_fold} = Replay.fold(prefix)
    assert {:ok, second_fold} = Replay.fold(prefix)
    assert first_fold == second_fold
    assert first_fold.last_event_seq == maximum

    assert first_fold.attempts[unknown.attempt_id].state == :outcome_unknown
    assert :needs_owner in first_fold.actions[unknown.action_id].blockers
    assert first_fold.attempts[completed.attempt_id].state == :succeeded
    assert first_fold.actions[completed.action_id].resolution == :succeeded

    assert first_fold.artifacts[available_ref].expected_state == :available
    assert first_fold.artifacts[pending_ref].expected_state == :deletion_pending
    assert first_fold.artifacts[pending_ref].request_event_id == pending_request.event_id
    assert first_fold.artifacts[tombstoned_ref].expected_state == :tombstoned
    assert first_fold.artifacts[tombstoned_ref].request_event_id == tombstone_request.event_id
    assert first_fold.artifacts[tombstoned_ref].tombstone_event_id == tombstone.event_id

    assert {:ok, report} = RecoveryOracle.inspect_prefix()
    assert report.derived == first_fold
    assert Court.max_event_seq() == maximum
    assert report.artifact_resolutions[available_ref].state == :available
    assert report.artifact_resolutions[pending_ref].state == :deletion_pending
    assert report.artifact_resolutions[pending_ref].request_event_id == pending_request.event_id
    assert report.artifact_recovery[pending_ref] == :delete_then_tombstone
    assert report.artifact_resolutions[tombstoned_ref].state == :tombstoned
  end

  test "a non-prefix is rejected rather than normalized or invented" do
    assert {:error, %Error{code: :invalid_prefix}} =
             Replay.fold([fixture_event(2, "resident_created")])
  end

  test "a hand-written prefix derives one exact canonical literal" do
    pending_ref = "sha256:" <> String.duplicate("1", 64)

    prefix = [
      fixture_event(1, "resident_created"),
      fixture_event(2, "incarnation_started"),
      fixture_event(3, "resident_paused", %{"resumable" => true}),
      fixture_event(
        4,
        "synthetic_action_proposed",
        %{"action_id" => "action", "idempotency" => "non_idempotent"},
        [pending_ref]
      ),
      fixture_event(5, "synthetic_action_approved", %{"action_id" => "action"}),
      fixture_event(6, "synthetic_attempt_claimed", %{
        "action_id" => "action",
        "attempt_id" => "attempt",
        "idempotency" => "non_idempotent"
      }),
      fixture_event(7, "synthetic_attempt_dispatched", %{
        "action_id" => "action",
        "attempt_id" => "attempt",
        "idempotency" => "non_idempotent"
      }),
      fixture_event(8, "artifact_deletion_requested", %{"artifact_ref" => pending_ref})
    ]

    assert {:ok,
            %{
              last_event_seq: 8,
              event_ids: event_ids,
              actions: %{
                "action" => %{
                  phase: :active,
                  resolution: nil,
                  blockers: [:needs_owner],
                  idempotency: "non_idempotent",
                  attempt_ids: ["attempt"]
                }
              },
              attempts: %{
                "attempt" => %{
                  action_id: "action",
                  state: :outcome_unknown,
                  event_id: "event-7",
                  idempotency: "non_idempotent"
                }
              },
              artifacts: %{
                ^pending_ref => %{
                  expected_state: :deletion_pending,
                  request_event_id: "event-8",
                  tombstone_event_id: nil,
                  referenced_by: ["event-4"]
                }
              },
              lifecycle: %{
                resident_ids: resident_ids,
                incarnations: %{
                  "incarnation" => %{
                    resident_id: "resident",
                    state: :started,
                    start_event_id: "event-2",
                    terminal_event_id: nil,
                    inference_event_id: nil
                  }
                }
              },
              projections: %{},
              scheduler: %{"resident" => :paused}
            }} = Replay.fold(prefix)

    assert event_ids == MapSet.new(Enum.map(1..8, &"event-#{&1}"))
    assert resident_ids == MapSet.new(["resident"])
  end

  defp fixture_event(sequence, event_type, payload \\ %{}, artifact_refs \\ []) do
    %Court.Event{
      event_seq: sequence,
      recorded_at: ~U[2026-08-08 00:00:00.000000Z],
      event_id: "event-#{sequence}",
      event_type: event_type,
      schema_version: 1,
      occurred_at: ~U[2026-08-08 00:00:00.000000Z],
      actor: "worker/synthetic",
      resident_id: "resident",
      incarnation_id: "incarnation",
      payload: payload,
      artifact_refs: artifact_refs
    }
  end
end
