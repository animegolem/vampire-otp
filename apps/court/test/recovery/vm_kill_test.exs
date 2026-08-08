defmodule Court.Recovery.VmKillTest do
  use ExUnit.Case, async: false

  alias Court.Replay

  @cuts [
    {:court_append_before_commit, :writer, false},
    {:court_append_committed_before_ack, :writer, true},
    {:publication_staging_written, :publication, nil},
    {:publication_file_synced, :publication, nil},
    {:publication_renamed, :publication, nil},
    {:publication_directory_synced, :publication, nil},
    {:publication_reference_committed_before_ack, :publication_reference, true},
    {:deletion_request_before_commit, :deletion, {:available, :none}},
    {:deletion_request_committed_before_ack, :deletion,
     {:deletion_pending, :delete_then_tombstone}},
    {:deletion_before_unlink, :deletion, {:deletion_pending, :delete_then_tombstone}},
    {:deletion_bytes_deleted, :deletion, {:deletion_pending, :commit_tombstone}},
    {:deletion_directory_synced, :deletion, {:deletion_pending, :commit_tombstone}},
    {:deletion_tombstone_committed, :deletion, {:tombstoned, :none}},
    {:scheduler_pause_committed, :scheduler, :paused}
  ]

  @tag timeout: 120_000
  test "SIGKILL at every durability cut replays exactly the maximal committed prefix" do
    mix = System.find_executable("mix") || flunk("mix executable is unavailable")

    for {cut, family, writer_committed?} <- @cuts do
      paths = paths(cut)
      on_exit(fn -> File.rm_rf!(paths.root) end)
      env = env(paths)
      port = start_cut_vm(mix, cut, env)
      {beam_pid, marker} = await_ready(port, cut, "")

      {_output, 0} = System.cmd("/bin/kill", ["-KILL", beam_pid], stderr_to_stdout: true)
      await_port_exit(port, "")

      report = verify_after_restart(mix, env)
      assert report.maximum_event_seq == report.derived.last_event_seq
      assert {:ok, report.derived} == Replay.fold(report.events)
      assert MapSet.size(report.derived.event_ids) == report.maximum_event_seq
      assert unknown_non_idempotent_attempt?(report.derived)
      assert_one_crash_inference_without_synthetic_end(report.derived)

      assert Enum.count(report.events, &(&1.event_type == "incarnation_crash_inferred")) == 1

      assert_all_artifacts_ruled(report)
      assert report.scheduler_cache == report.derived.scheduler
      assert_marker(family, marker, writer_committed?, report)
    end
  end

  defp start_cut_vm(mix, cut, env) do
    Port.open(
      {:spawn_executable, mix},
      [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:args,
         [
           "run",
           "--no-compile",
           "--no-deps-check",
           driver_path(),
           "--",
           "cut",
           Atom.to_string(cut)
         ]},
        {:cd, repo_root()},
        {:env, encode_env(env)}
      ]
    )
  end

  defp await_ready(port, cut, output) do
    receive do
      {^port, {:data, bytes}} ->
        output = output <> bytes

        case ready_line(output, cut) do
          {:ok, result} -> result
          :pending -> await_ready(port, cut, output)
        end

      {^port, {:exit_status, status}} ->
        flunk("cut VM exited before its handshake (#{status}):\n#{output}")
    after
      15_000 -> flunk("cut VM never reached #{cut}:\n#{output}")
    end
  end

  defp ready_line(output, cut) do
    expected = Atom.to_string(cut)

    output
    |> String.split("\n")
    |> Enum.find_value(:pending, fn line ->
      case String.split(line, "\t") do
        ["VOTP_READY", beam_pid, ^expected, nonce, marker] when nonce != "" ->
          {:ok, {beam_pid, marker}}

        _other ->
          false
      end
    end)
  end

  defp await_port_exit(port, output) do
    receive do
      {^port, {:data, bytes}} -> await_port_exit(port, output <> bytes)
      {^port, {:exit_status, status}} when status != 0 -> :ok
      {^port, {:exit_status, 0}} -> flunk("SIGKILL child exited successfully:\n#{output}")
    after
      10_000 -> flunk("SIGKILL child did not exit:\n#{output}")
    end
  end

  defp verify_after_restart(mix, env) do
    {output, status} =
      System.cmd(
        mix,
        ["run", "--no-compile", "--no-deps-check", driver_path(), "--", "verify"],
        cd: repo_root(),
        env: env,
        stderr_to_stdout: true
      )

    assert status == 0, output

    encoded =
      output
      |> String.split("\n")
      |> Enum.find_value(fn line ->
        case String.split(line, "\t") do
          ["VOTP_RESULT", value] -> value
          _other -> nil
        end
      end)

    assert is_binary(encoded), output
    encoded |> Base.decode64!() |> :erlang.binary_to_term()
  end

  defp unknown_non_idempotent_attempt?(derived) do
    Enum.any?(derived.attempts, fn {_attempt_id, attempt} ->
      attempt.state == :outcome_unknown and attempt.idempotency == "non_idempotent" and
        :needs_owner in derived.actions[attempt.action_id].blockers
    end)
  end

  defp assert_one_crash_inference_without_synthetic_end(derived) do
    inferred =
      Enum.filter(derived.lifecycle.incarnations, fn {_incarnation_id, incarnation} ->
        incarnation.state == :crash_inferred
      end)

    assert [{_incarnation_id, incarnation}] = inferred
    assert is_nil(incarnation.terminal_event_id)
    assert is_binary(incarnation.inference_event_id)
  end

  defp assert_all_artifacts_ruled(report) do
    states =
      report.artifact_resolutions
      |> Map.values()
      |> Enum.map(& &1.state)

    assert :available in states
    assert :tombstoned in states
    assert :deletion_pending in states

    for {_ref, resolution} <- report.artifact_resolutions do
      assert resolution.state in [:available, :tombstoned, :deletion_pending]
      refute resolution.integrity_fault

      if resolution.state == :deletion_pending do
        assert is_binary(resolution.request_event_id)

        assert report.artifact_recovery[resolution.ref] in [
                 :delete_then_tombstone,
                 :commit_tombstone
               ]
      else
        assert report.artifact_recovery[resolution.ref] == :none
      end
    end
  end

  defp assert_marker(:writer, event_id, should_commit?, report) do
    assert MapSet.member?(report.derived.event_ids, event_id) == should_commit?
  end

  defp assert_marker(:publication, ref, _should_commit?, report) do
    refute Map.has_key?(report.derived.artifacts, ref)
  end

  defp assert_marker(:publication_reference, event_id, true, report) do
    event = Enum.find(report.events, &(&1.event_id == event_id))
    assert event.event_type == "vm_publication_reference"
    assert [ref] = event.artifact_refs
    assert report.artifact_resolutions[ref].state == :available
  end

  defp assert_marker(:deletion, ref, {expected_state, recovery_action}, report) do
    assert report.artifact_resolutions[ref].state == expected_state
    assert report.artifact_recovery[ref] == recovery_action

    if expected_state in [:deletion_pending, :tombstoned] do
      assert is_binary(report.artifact_resolutions[ref].request_event_id)
    end
  end

  defp assert_marker(:scheduler, event_id, :paused, report) do
    event = Enum.find(report.events, &(&1.event_id == event_id))
    assert event.event_type == "resident_paused"
    assert report.derived.scheduler[event.resident_id] == :paused
    assert report.scheduler_cache[event.resident_id] == :paused
  end

  defp paths(cut) do
    nonce = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

    root =
      Path.join(
        System.tmp_dir!(),
        "vampire_otp_vm_#{cut}_#{nonce}"
      )

    File.mkdir_p!(root)

    %{
      root: root,
      database: Path.join(root, "court.sqlite3"),
      artifacts: Path.join(root, "artifacts"),
      logs: Path.join(root, "logs.txt")
    }
  end

  defp env(paths) do
    [
      {"MIX_ENV", "test"},
      {"VAMPIRE_OTP_TEST_DB", paths.database},
      {"VAMPIRE_OTP_ARTIFACT_ROOT", paths.artifacts},
      {"VAMPIRE_OTP_LOGS_PATH", paths.logs}
    ]
  end

  defp encode_env(env) do
    Enum.map(env, fn {key, value} -> {String.to_charlist(key), String.to_charlist(value)} end)
  end

  defp repo_root, do: Path.expand("../../../../", __DIR__)
  defp driver_path, do: Path.join(repo_root(), "apps/court/priv/recovery_vm_driver.exs")
end
