defmodule Court.Replay do
  @moduledoc """
  Pure canonical fold of an exact committed court prefix.

  The fold performs no I/O and never speculates beyond its input.
  External artifact bytes are reconciled separately by
  `Court.RecoveryOracle`.
  """

  alias Court.{Error, Event}

  @initial %{
    last_event_seq: 0,
    event_ids: MapSet.new(),
    actions: %{},
    attempts: %{},
    artifacts: %{},
    lifecycle: %{resident_ids: MapSet.new(), incarnations: %{}},
    projections: %{},
    scheduler: %{}
  }

  @spec fold([Event.t()]) :: {:ok, map()} | {:error, Error.t()}
  def fold(events) when is_list(events) do
    with :ok <- exact_prefix(events) do
      state = Enum.reduce(events, @initial, &apply_event/2)
      {:ok, finalize_unknown_attempts(state)}
    end
  end

  def fold(_events), do: invalid_prefix(%{events: "must be a list"})

  defp exact_prefix(events) do
    actual = Enum.map(events, & &1.event_seq)
    expected = if events == [], do: [], else: Enum.to_list(1..length(events))

    if actual == expected, do: :ok, else: invalid_prefix(%{expected: expected, actual: actual})
  end

  defp apply_event(%Event{} = event, state) do
    state
    |> Map.put(:last_event_seq, event.event_seq)
    |> Map.update!(:event_ids, &MapSet.put(&1, event.event_id))
    |> fold_artifact_refs(event)
    |> fold_artifact_transition(event)
    |> fold_lifecycle(event)
    |> fold_scheduler(event)
    |> fold_projection(event)
    |> fold_action(event)
  end

  defp fold_artifact_refs(state, event) do
    Enum.reduce(event.artifact_refs, state, fn ref, acc ->
      update_in(acc, [:artifacts], fn artifacts ->
        Map.put_new(artifacts, ref, %{
          expected_state: :available,
          request_event_id: nil,
          tombstone_event_id: nil,
          referenced_by: [event.event_id]
        })
        |> Map.update!(ref, fn artifact ->
          Map.update!(
            artifact,
            :referenced_by,
            &([event.event_id | &1] |> Enum.uniq() |> Enum.sort())
          )
        end)
      end)
    end)
  end

  defp fold_artifact_transition(state, %{event_type: "artifact_deletion_requested"} = event) do
    ref = get_in(event.payload, ["artifact_ref"])

    put_in(state, [:artifacts, ref], %{
      expected_state: :deletion_pending,
      request_event_id: event.event_id,
      tombstone_event_id: nil,
      referenced_by: get_in(state, [:artifacts, ref, :referenced_by]) || []
    })
  end

  defp fold_artifact_transition(state, %{event_type: "artifact_tombstoned"} = event) do
    ref = get_in(event.payload, ["artifact_ref"])
    prior = Map.get(state.artifacts, ref, %{})

    put_in(state, [:artifacts, ref], %{
      expected_state: :tombstoned,
      request_event_id: Map.get(prior, :request_event_id),
      tombstone_event_id: event.event_id,
      referenced_by: Map.get(prior, :referenced_by, [])
    })
  end

  defp fold_artifact_transition(state, _event), do: state

  defp fold_lifecycle(state, %{event_type: "resident_created"} = event) do
    update_in(state, [:lifecycle, :resident_ids], &MapSet.put(&1, event.resident_id))
  end

  defp fold_lifecycle(state, %{event_type: "incarnation_started"} = event) do
    put_in(state, [:lifecycle, :incarnations, event.incarnation_id], %{
      resident_id: event.resident_id,
      state: :started,
      start_event_id: event.event_id,
      terminal_event_id: nil,
      inference_event_id: nil
    })
  end

  defp fold_lifecycle(state, %{event_type: "incarnation_ended"} = event) do
    update_in(state, [:lifecycle, :incarnations, event.incarnation_id], fn prior ->
      Map.merge(prior || %{}, %{state: :ended, terminal_event_id: event.event_id})
    end)
  end

  defp fold_lifecycle(state, %{event_type: "incarnation_crash_inferred"} = event) do
    orphan_id = get_in(event.payload, ["orphan_incarnation_id"])

    update_in(state, [:lifecycle, :incarnations, orphan_id], fn prior ->
      Map.merge(prior || %{}, %{state: :crash_inferred, inference_event_id: event.event_id})
    end)
  end

  defp fold_lifecycle(state, _event), do: state

  defp fold_scheduler(state, %{event_type: "resident_paused"} = event),
    do: put_in(state, [:scheduler, event.resident_id], :paused)

  defp fold_scheduler(state, %{event_type: "resident_resumed"} = event) do
    case Map.get(state.scheduler, event.resident_id) do
      :stopped -> state
      _prior -> put_in(state, [:scheduler, event.resident_id], :running)
    end
  end

  defp fold_scheduler(state, %{event_type: "resident_stopped"} = event),
    do: put_in(state, [:scheduler, event.resident_id], :stopped)

  defp fold_scheduler(state, _event), do: state

  defp fold_projection(state, %{event_type: "projection_created"} = event) do
    projection_id = get_in(event.payload, ["projection_id"])

    put_in(state, [:projections, projection_id], %{
      descriptor: event.payload,
      created_event_id: event.event_id,
      status: :active,
      replacement_projection_id: nil,
      superseded_event_id: nil
    })
  end

  defp fold_projection(state, %{event_type: "projection_superseded"} = event) do
    projection_id = get_in(event.payload, ["superseded_projection_id"])
    replacement_id = get_in(event.payload, ["replacement_projection_id"])

    update_in(state, [:projections, projection_id], fn prior ->
      Map.merge(prior || %{}, %{
        status: :superseded,
        replacement_projection_id: replacement_id,
        superseded_event_id: event.event_id
      })
    end)
  end

  defp fold_projection(state, _event), do: state

  defp fold_action(state, %{event_type: "synthetic_action_proposed"} = event) do
    action_id = get_in(event.payload, ["action_id"])

    put_in(state, [:actions, action_id], %{
      phase: :proposed,
      resolution: nil,
      blockers: [],
      idempotency: get_in(event.payload, ["idempotency"]),
      attempt_ids: []
    })
  end

  defp fold_action(state, %{event_type: "synthetic_action_approved"} = event),
    do: update_action(state, event, &Map.put(&1, :phase, :approved))

  defp fold_action(state, %{event_type: "synthetic_attempt_claimed"} = event) do
    state
    |> put_attempt(event, :claimed)
    |> update_action(event, fn action ->
      action
      |> Map.put(:phase, :active)
      |> Map.update!(:attempt_ids, &([get_in(event.payload, ["attempt_id"]) | &1] |> Enum.uniq()))
    end)
  end

  defp fold_action(state, %{event_type: "synthetic_attempt_dispatched"} = event),
    do: put_attempt(state, event, :dispatched)

  defp fold_action(state, %{event_type: "synthetic_attempt_succeeded"} = event),
    do: resolve_action(state, event, :succeeded)

  defp fold_action(state, %{event_type: "synthetic_attempt_failed"} = event),
    do: resolve_action(state, event, :failed)

  defp fold_action(state, _event), do: state

  defp put_attempt(state, event, attempt_state) do
    action_id = get_in(event.payload, ["action_id"])
    attempt_id = get_in(event.payload, ["attempt_id"])

    put_in(state, [:attempts, attempt_id], %{
      action_id: action_id,
      state: attempt_state,
      event_id: event.event_id,
      idempotency: get_in(event.payload, ["idempotency"])
    })
  end

  defp resolve_action(state, event, resolution) do
    state
    |> put_attempt(event, resolution)
    |> update_action(event, &Map.merge(&1, %{phase: :resolved, resolution: resolution}))
  end

  defp update_action(state, event, update) do
    action_id = get_in(event.payload, ["action_id"])
    update_in(state, [:actions, action_id], fn action -> update.(action || %{}) end)
  end

  defp finalize_unknown_attempts(state) do
    Enum.reduce(state.attempts, state, fn
      {attempt_id, %{state: :dispatched} = attempt}, acc ->
        acc = put_in(acc, [:attempts, attempt_id, :state], :outcome_unknown)

        if attempt.idempotency == "non_idempotent" do
          update_in(acc, [:actions, attempt.action_id, :blockers], fn blockers ->
            [:needs_owner | blockers || []] |> Enum.uniq() |> Enum.sort()
          end)
        else
          acc
        end

      {_attempt_id, _attempt}, acc ->
        acc
    end)
  end

  defp invalid_prefix(details) do
    {:error,
     %Error{
       code: :invalid_prefix,
       message: "events are not an exact committed prefix",
       details: details
     }}
  end
end
