defmodule Court.Recovery.ChildKillTest do
  use ExUnit.Case, async: false

  @cuts [
    {:court_append_before_commit, false},
    {:court_append_committed_before_ack, true}
  ]

  test "writer death distinguishes an open transaction from a lost acknowledgement" do
    on_exit(&Court.Failpoint.disarm/0)

    for {phase, should_commit?} <- @cuts do
      event_id = Court.new_id()
      attrs = event(event_id, phase)
      writer = Process.whereis(Court.Writer)
      writer_monitor = Process.monitor(writer)
      nonce = Court.Failpoint.arm(phase, %{event_id: event_id}, self())

      {_caller, caller_monitor} = spawn_monitor(fn -> Court.append(attrs) end)

      assert_receive {:court_failpoint, ^nonce, ^phase, metadata, ^writer}, 2_000
      assert metadata.event_id == event_id

      Process.exit(writer, :kill)
      assert_receive {:DOWN, ^writer_monitor, :process, ^writer, :killed}, 2_000
      assert_receive {:DOWN, ^caller_monitor, :process, _caller, _reason}, 2_000
      await_restarted_writer(writer, System.monotonic_time(:millisecond) + 2_000)

      case Court.by_event_id(event_id) do
        {:ok, committed} -> assert should_commit? and committed.event_id == event_id
        {:error, %Court.Error{code: :not_found}} -> refute should_commit?
      end
    end
  end

  defp event(event_id, phase) do
    %{
      event_id: event_id,
      event_type: "writer_kill_probe",
      schema_version: 1,
      occurred_at: DateTime.utc_now(),
      actor: "worker/synthetic",
      resident_id: Court.new_id(),
      incarnation_id: Court.new_id(),
      payload: %{"cut" => Atom.to_string(phase)},
      artifact_refs: []
    }
  end

  defp await_restarted_writer(old_pid, deadline) do
    case Process.whereis(Court.Writer) do
      pid when is_pid(pid) and pid != old_pid ->
        pid

      _other ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("Court supervisor did not restart Writer")
        else
          :erlang.yield()
          await_restarted_writer(old_pid, deadline)
        end
    end
  end
end
