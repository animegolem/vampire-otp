defmodule Runtime.LifecycleTest do
  use ExUnit.Case, async: false

  alias Court.Writer
  alias Runtime.Lifecycle
  alias Runtime.Lifecycle.Identity

  defp event(event_type, resident_id, incarnation_id, payload \\ %{}) do
    %{
      event_id: Court.new_id(),
      event_type: event_type,
      schema_version: 1,
      occurred_at: DateTime.utc_now(),
      actor: "resident",
      resident_id: resident_id,
      incarnation_id: incarnation_id,
      payload: payload,
      artifact_refs: []
    }
  end

  defp start_orphan(%Identity{} = current) do
    orphan_id = Court.new_id()

    assert {:ok, started} =
             Writer.ensure_incarnation_started(
               event("incarnation_started", current.resident_id, orphan_id)
             )

    {orphan_id, started}
  end

  test "application boot records one resident root and its incarnation" do
    current = Lifecycle.identity()
    assert current.incarnation_id == Runtime.BootIdentity.current()

    assert {:ok, resident_events} = Court.by_type("resident_created")
    assert Enum.uniq_by(resident_events, & &1.resident_id) == [hd(resident_events)]
    assert hd(resident_events).resident_id == current.resident_id

    assert {:ok, starts} = Court.by_type("incarnation_started")
    assert Enum.any?(starts, &(&1.incarnation_id == current.incarnation_id))
  end

  test "clean terminal prevents crash inference" do
    current = Lifecycle.identity()
    {incarnation_id, started} = start_orphan(current)
    identity = %Identity{resident_id: current.resident_id, incarnation_id: incarnation_id}

    assert {:ok, ended} = Lifecycle.end_incarnation(identity)
    assert ended.causation_id == started.event_id
    assert {:ok, _events} = Lifecycle.scan_orphans()

    assert {:ok, inferences} = Court.by_type("incarnation_crash_inferred")

    refute Enum.any?(
             inferences,
             &(get_in(&1.payload, ["orphan_incarnation_id"]) == incarnation_id)
           )
  end

  test "a supervised child kill restarts with the same boot incarnation" do
    current = Lifecycle.identity()
    old_pid = Process.whereis(Lifecycle)
    monitor = Process.monitor(old_pid)
    Process.exit(old_pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^old_pid, :killed}, 1_000

    new_pid = await_restarted_lifecycle(old_pid, System.monotonic_time(:millisecond) + 1_000)
    assert new_pid != old_pid
    assert Lifecycle.identity() == current

    assert {:ok, starts} = Court.by_type("incarnation_started")
    assert Enum.count(starts, &(&1.incarnation_id == current.incarnation_id)) == 1
  end

  test "a clean lifecycle shutdown records its terminal event" do
    incarnation_id = Court.new_id()
    assert {:ok, pid} = Lifecycle.start_link(incarnation_id: incarnation_id, name: nil)
    Process.unlink(pid)
    identity = Lifecycle.identity(pid)
    assert :ok = GenServer.stop(pid, :shutdown)

    assert {:ok, ended} = Court.by_type("incarnation_ended")
    assert Enum.count(ended, &(&1.incarnation_id == identity.incarnation_id)) == 1
  end

  test "repeated and concurrent scans infer one crash and never synthesize an ending" do
    current = Lifecycle.identity()
    {orphan_id, started} = start_orphan(current)

    results =
      1..10
      |> Task.async_stream(fn _ -> Lifecycle.scan_orphans() end, max_concurrency: 10)
      |> Enum.to_list()

    assert Enum.all?(results, &match?({:ok, {:ok, _}}, &1))
    assert {:ok, _events} = Lifecycle.scan_orphans()

    assert {:ok, inferences} = Court.by_type("incarnation_crash_inferred")

    matching =
      Enum.filter(inferences, &(get_in(&1.payload, ["orphan_incarnation_id"]) == orphan_id))

    assert [inference] = matching
    assert inference.actor == "recovery"
    assert inference.causation_id == started.event_id

    assert {:ok, ended} = Court.by_type("incarnation_ended")
    refute Enum.any?(ended, &(&1.incarnation_id == orphan_id))
  end

  test "multi-orphan scan records exactly one inference per incarnation" do
    current = Lifecycle.identity()
    orphan_ids = for _ <- 1..3, do: elem(start_orphan(current), 0)

    assert {:ok, _events} = Lifecycle.scan_orphans()
    assert {:ok, inferences} = Court.by_type("incarnation_crash_inferred")

    for orphan_id <- orphan_ids do
      assert Enum.count(inferences, &(get_in(&1.payload, ["orphan_incarnation_id"]) == orphan_id)) ==
               1
    end
  end

  defp await_restarted_lifecycle(old_pid, deadline) do
    case Process.whereis(Lifecycle) do
      pid when is_pid(pid) and pid != old_pid ->
        pid

      _ ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("Runtime supervisor did not restart Lifecycle")
        else
          :erlang.yield()
          await_restarted_lifecycle(old_pid, deadline)
        end
    end
  end
end
