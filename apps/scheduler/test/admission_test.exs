defmodule Scheduler.AdmissionTest do
  use ExUnit.Case, async: false

  alias Scheduler.{Admission, Error}

  defp context(overrides \\ %{}) do
    Map.merge(
      %{
        actor: "owner",
        resident_id: Court.new_id(),
        incarnation_id: Court.new_id(),
        occurred_at: DateTime.utc_now()
      },
      overrides
    )
  end

  defp events(event_type, resident_id) do
    {:ok, all} = Court.by_type(event_type)
    Enum.filter(all, &(&1.resident_id == resident_id))
  end

  test "pause denies and records admission, while resume restores it" do
    recording = context()
    assert {:ok, grant} = Admission.request_admission(recording)
    assert is_reference(grant)

    assert {:ok, paused} = Admission.pause(recording)
    assert paused.event_type == "resident_paused"
    assert paused.payload == %{"resumable" => true}
    assert Admission.state(recording.resident_id) == :paused

    assert {:denied, :paused} = Admission.request_admission(recording)
    assert [denial] = events("admission_denied", recording.resident_id)
    assert denial.payload["reason"] == "paused"
    assert denial.causation_id == paused.event_id

    assert {:ok, resumed} = Admission.resume(recording)
    assert resumed.event_type == "resident_resumed"
    assert {:ok, grant} = Admission.request_admission(recording)
    assert is_reference(grant)
  end

  test "terminal stop is distinct and every resume attempt is recorded as denied" do
    recording = context()
    assert {:ok, stopped} = Admission.stop(recording)
    assert stopped.event_type == "resident_stopped"
    assert stopped.payload == %{"terminal" => true}
    assert Admission.state(recording.resident_id) == :stopped

    assert {:ok, denied} = Admission.resume(recording)
    assert denied.event_type == "lifecycle_transition_denied"
    assert denied.payload["requested_transition"] == "resume"
    assert Admission.state(recording.resident_id) == :stopped
    assert {:denied, :stopped} = Admission.request_admission(recording)
  end

  test "same-state commands are no-ops" do
    recording = context()
    assert {:ok, _paused} = Admission.pause(recording)
    count = length(events("resident_paused", recording.resident_id))
    assert {:ok, :noop} = Admission.pause(recording)
    assert length(events("resident_paused", recording.resident_id)) == count

    assert {:ok, _stopped} = Admission.stop(recording)
    stopped_count = length(events("resident_stopped", recording.resident_id))
    assert {:ok, :noop} = Admission.stop(recording)
    assert length(events("resident_stopped", recording.resident_id)) == stopped_count
  end

  test "state rebuild after process kill preserves pause and stop" do
    paused_context = context()
    stopped_context = context()
    assert {:ok, _paused} = Admission.pause(paused_context)
    assert {:ok, _stopped} = Admission.stop(stopped_context)

    old_pid = Process.whereis(Admission)
    monitor = Process.monitor(old_pid)
    Process.exit(old_pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^old_pid, :killed}, 1_000
    await_restarted_admission(old_pid, System.monotonic_time(:millisecond) + 1_000)

    assert Admission.state(paused_context.resident_id) == :paused
    assert Admission.state(stopped_context.resident_id) == :stopped
    assert {:denied, :paused} = Admission.request_admission(paused_context)
    assert {:denied, :stopped} = Admission.request_admission(stopped_context)
  end

  test "invalid recording context is a typed denial, never an accidental grant" do
    assert {:error, %Error{code: :invalid_context}} =
             Admission.request_admission(%{resident_id: "", incarnation_id: ""})
  end

  defp await_restarted_admission(old_pid, deadline) do
    case Process.whereis(Admission) do
      pid when is_pid(pid) and pid != old_pid ->
        pid

      _ ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("Scheduler supervisor did not restart Admission")
        else
          :erlang.yield()
          await_restarted_admission(old_pid, deadline)
        end
    end
  end
end
