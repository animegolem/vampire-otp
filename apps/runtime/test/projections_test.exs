defmodule Runtime.ProjectionsTest do
  use ExUnit.Case, async: false

  alias Runtime.{ProjectionError, Projections.Cursor, Projections.Logs, Projections.Registry}

  defp court_event(event_type, payload) do
    identity = Runtime.Lifecycle.identity()

    %{
      event_id: Court.new_id(),
      event_type: event_type,
      schema_version: 1,
      occurred_at: DateTime.utc_now(),
      actor: "worker/projection-test",
      resident_id: identity.resident_id,
      incarnation_id: identity.incarnation_id,
      payload: payload,
      artifact_refs: []
    }
  end

  defp version(label), do: "#{label}-#{System.unique_integer([:positive])}"

  defp configured_path do
    :runtime
    |> Application.fetch_env!(Logs)
    |> Keyword.fetch!(:path)
  end

  defp expected_prefix(target) do
    if target == 0 do
      <<>>
    else
      {:ok, events} = Court.by_seq_range(1, target)
      events |> Enum.map(&Logs.render/1) |> IO.iodata_to_binary()
    end
  end

  test "renderer is pure across payload key order and escapes line structure" do
    attrs = court_event("projection_render_test", %{"b" => 2, "a" => "line\nwith\ttabs"})
    assert {:ok, first} = Court.append(attrs)

    reordered = %{first | payload: %{"a" => "line\nwith\ttabs", "b" => 2}}
    assert Logs.render(first) == Logs.render(reordered)

    [line, ""] = String.split(Logs.render(first), "\n")
    assert String.starts_with?(line, "#{first.event_seq}\t")
    assert line =~ ~s({"a", "line\\nwith\\ttabs"})

    for item <- 1..128 do
      variant = %{
        first
        | session_id: if(rem(item, 2) == 0, do: "session-#{item}", else: nil),
          episode_id: if(rem(item, 3) == 0, do: "episode-#{item}", else: nil),
          payload: %{"item" => item, "nested" => [%{"even" => rem(item, 2) == 0}, nil]}
      }

      rendered = Logs.render(variant)
      assert String.starts_with?(rendered, "#{variant.event_seq}\t")
      assert String.ends_with?(rendered, "\n")
      assert length(String.split(rendered, "\n", trim: true)) == 1
    end
  end

  test "build captures an explicit prefix before its registry event" do
    projection_version = version("prefix")
    assert {:ok, result} = Logs.build(version: projection_version)
    assert result.created.event_seq > result.target_event_seq

    assert {:ok, cursor} = Cursor.recover(configured_path())
    assert cursor == result.target_event_seq
    assert File.read!(configured_path()) == expected_prefix(result.target_event_seq)

    descriptor = result.created.payload
    assert descriptor["cursor"] == result.target_event_seq
    assert descriptor["content_ref"] == result.content_ref
    assert descriptor["producer"]["module"] == "Runtime.Projections.Logs"
    assert descriptor["precision"] == "exact"
    assert descriptor["trust"] == "derived"
  end

  test "same-definition loss rebuild is byte-identical and emits no registry event" do
    projection_version = version("loss")
    assert {:ok, built} = Logs.build(version: projection_version)
    original = File.read!(configured_path())
    {:ok, created_before} = Court.by_type("projection_created")
    {:ok, superseded_before} = Court.by_type("projection_superseded")

    assert :ok = File.rm(configured_path())
    assert {:ok, rebuilt} = Logs.rebuild(version: projection_version)
    assert rebuilt.target_event_seq == built.target_event_seq
    assert File.read!(configured_path()) == original

    {:ok, created_after} = Court.by_type("projection_created")
    {:ok, superseded_after} = Court.by_type("projection_superseded")
    assert length(created_after) == length(created_before)
    assert length(superseded_after) == length(superseded_before)
  end

  test "definition changes create a new version and supersede the prior" do
    first_version = version("definition-a")
    second_version = version("definition-b")
    assert {:ok, first} = Logs.build(version: first_version)
    assert {:ok, second} = Logs.build(version: second_version)

    assert second.created.payload["definition_digest"] !=
             first.created.payload["definition_digest"]

    assert second.superseded.payload["superseded_projection_id"] ==
             first.created.payload["projection_id"]

    assert second.superseded.payload["replacement_projection_id"] ==
             second.created.payload["projection_id"]

    assert {:ok, active} = Registry.active()
    assert active.event_id == second.created.event_id
  end

  test "incremental output equals a from-zero rendering for the captured prefix" do
    projection_version = version("incremental")

    for item <- 1..500 do
      assert {:ok, _event} =
               Court.append(court_event("projection_bulk_event", %{"item" => item}))
    end

    assert {:ok, _built} = Logs.build(version: projection_version)

    for item <- 501..510 do
      assert {:ok, _event} =
               Court.append(court_event("projection_bulk_event", %{"item" => item}))
    end

    assert {:ok, caught_up} = Logs.catch_up()
    assert caught_up.appended >= 10
    assert File.read!(configured_path()) == expected_prefix(caught_up.target_event_seq)
  end

  test "torn suffix is truncated and complete-line cursor prevents duplication" do
    path = Path.join(System.tmp_dir!(), "cursor-cut-#{System.unique_integer([:positive])}.txt")
    assert :ok = Cursor.replace(path, "1\tfirst\n")

    assert catch_throw(
             Cursor.append_lines(path, ["2\tsecond\n"],
               partial_at: 1,
               checkpoint: fn phase, _metadata ->
                 if phase == :partial_line_synced, do: throw(:partial_cut)
               end
             )
           ) == :partial_cut

    assert {:ok, 1} = Cursor.recover(path)
    assert File.read!(path) == "1\tfirst\n"
    assert :ok = Cursor.append_lines(path, ["2\tsecond\n"])
    assert {:ok, 2} = Cursor.recover(path)

    assert catch_throw(
             Cursor.append_lines(path, ["3\tthird\n"],
               checkpoint: fn phase, _metadata ->
                 if phase == :complete_lines_synced, do: throw(:complete_cut)
               end
             )
           ) == :complete_cut

    assert {:ok, 3} = Cursor.recover(path)
    assert File.read!(path) == "1\tfirst\n2\tsecond\n3\tthird\n"
  end

  test "complete corruption is an integrity fault rather than a rebuild trigger" do
    path =
      Path.join(System.tmp_dir!(), "cursor-corrupt-#{System.unique_integer([:positive])}.txt")

    assert :ok = Cursor.replace(path, "1\tfirst\n3\tgap\n")

    assert {:error, %ProjectionError{code: :integrity_fault}} = Cursor.recover(path)
  end

  test "killing the projection consumer at partial and complete line cuts recovers exactly" do
    projection_version = version("consumer-kill")
    assert {:ok, _built} = Logs.build(version: projection_version)
    assert {:ok, _event} = Court.append(court_event("projection_kill_partial", %{}))

    kill_consumer_at(:partial_line_synced, partial_at: 1)
    assert {:ok, partial_recovery} = Logs.catch_up()
    assert File.read!(configured_path()) == expected_prefix(partial_recovery.target_event_seq)

    assert {:ok, _event} = Court.append(court_event("projection_kill_complete", %{}))
    kill_consumer_at(:complete_lines_synced)
    assert {:ok, complete_recovery} = Logs.catch_up()
    assert complete_recovery.appended == 0
    assert File.read!(configured_path()) == expected_prefix(complete_recovery.target_event_seq)
  end

  defp kill_consumer_at(target_phase, options \\ []) do
    parent = self()
    consumer = Process.whereis(Logs)
    consumer_monitor = Process.monitor(consumer)

    {_caller, caller_monitor} =
      spawn_monitor(fn ->
        checkpoint = fn phase, metadata ->
          if phase == target_phase do
            send(parent, {:projection_checkpoint, phase, metadata})

            receive do
              :continue_projection -> :ok
            end
          end
        end

        Logs.catch_up(Keyword.put(options, :checkpoint, checkpoint))
      end)

    assert_receive {:projection_checkpoint, ^target_phase, _metadata}, 2_000
    Process.exit(consumer, :kill)
    assert_receive {:DOWN, ^consumer_monitor, :process, ^consumer, :killed}, 2_000
    assert_receive {:DOWN, ^caller_monitor, :process, _caller, _reason}, 2_000

    await_restarted_logs(consumer, System.monotonic_time(:millisecond) + 1_000)
  end

  defp await_restarted_logs(old_pid, deadline) do
    case Process.whereis(Logs) do
      pid when is_pid(pid) and pid != old_pid ->
        pid

      _ ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("Runtime supervisor did not restart Logs")
        else
          :erlang.yield()
          await_restarted_logs(old_pid, deadline)
        end
    end
  end
end
