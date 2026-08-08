defmodule Court.RecoveryVmDriver do
  @moduledoc false

  alias Court.{Artifacts, Failpoint, RecoveryOracle}
  alias Court.Synthetic.Action

  @publication_phases %{
    "publication_staging_written" => :staging_written,
    "publication_file_synced" => :file_synced,
    "publication_renamed" => :renamed,
    "publication_directory_synced" => :directory_synced
  }

  @deletion_phases %{
    "deletion_before_unlink" => :deletion_before_unlink,
    "deletion_bytes_deleted" => :bytes_deleted,
    "deletion_directory_synced" => :deletion_directory_synced,
    "deletion_tombstone_committed" => :tombstone_committed
  }

  @writer_phases %{
    "court_append_before_commit" => :court_append_before_commit,
    "court_append_committed_before_ack" => :court_append_committed_before_ack
  }

  @deletion_request_phases %{
    "deletion_request_before_commit" => :court_append_before_commit,
    "deletion_request_committed_before_ack" => :court_append_committed_before_ack
  }

  def main(["cut", cut]) do
    identity = Runtime.Lifecycle.identity()
    context = context(identity)
    seed_oracle(context)

    cond do
      Map.has_key?(@writer_phases, cut) -> cut_writer(cut, context)
      cut == "publication_reference_committed_before_ack" -> cut_publication_reference(cut, context)
      Map.has_key?(@deletion_request_phases, cut) -> cut_deletion_request(cut, context)
      Map.has_key?(@publication_phases, cut) -> cut_publication(cut)
      Map.has_key?(@deletion_phases, cut) -> cut_deletion(cut, context)
      cut == "scheduler_pause_committed" -> cut_scheduler(cut, context)
      true -> abort("unknown cut #{inspect(cut)}")
    end
  end

  def main(["verify"]) do
    {:ok, []} = Runtime.Lifecycle.scan_orphans()
    {:ok, []} = Runtime.Lifecycle.scan_orphans()

    case RecoveryOracle.inspect_prefix() do
      {:ok, report} ->
        scheduler_cache =
          Map.new(report.derived.scheduler, fn {resident_id, _state} ->
            {resident_id, Scheduler.Admission.state(resident_id)}
          end)

        report = Map.put(report, :scheduler_cache, scheduler_cache)
        encoded = report |> :erlang.term_to_binary() |> Base.encode64()
        IO.puts("VOTP_RESULT\t#{encoded}")

      {:error, error} ->
        abort("oracle failed: #{inspect(error)}")
    end
  end

  def main(["--" | arguments]), do: main(arguments)

  def main(arguments), do: abort("invalid driver arguments: #{inspect(arguments)}")

  defp seed_oracle(context) do
    {:ok, available_ref} = Artifacts.publish("vm available #{Court.new_id()}")
    {:ok, pending_ref} = Artifacts.publish("vm pending #{Court.new_id()}")
    {:ok, tombstoned_ref} = Artifacts.publish("vm tombstoned #{Court.new_id()}")

    {:ok, _action, _events} =
      Action.dispatched_unknown(context,
        idempotency: :non_idempotent,
        artifact_refs: [available_ref, pending_ref, tombstoned_ref]
      )

    {:ok, _request} = Artifacts.delete_requested(pending_ref, context)
    {:ok, _request} = Artifacts.delete_requested(tombstoned_ref, context)
    {:ok, _tombstone} = Artifacts.complete_deletion(tombstoned_ref, context)
  end

  defp cut_writer(cut, context) do
    phase = Map.fetch!(@writer_phases, cut)
    event_id = Court.new_id()
    nonce = Failpoint.arm(phase, %{event_id: event_id}, self())

    spawn(fn -> Court.append(event(context, event_id, "vm_writer_cut", %{"cut" => cut}, [])) end)
    await_cut(nonce, phase, cut, event_id)
  end

  defp cut_publication(cut) do
    phase = Map.fetch!(@publication_phases, cut)
    content = "vm publication #{cut} #{Court.new_id()}"
    ref = content_ref(content)
    nonce = Failpoint.arm(phase, %{ref: ref}, self())

    spawn(fn ->
      Artifacts.publish(content, checkpoint: &Failpoint.hit/2)
    end)

    await_cut(nonce, phase, cut, ref)
  end

  defp cut_publication_reference(cut, context) do
    {:ok, ref} = Artifacts.publish("vm published reference #{Court.new_id()}")
    event_id = Court.new_id()
    phase = :court_append_committed_before_ack
    nonce = Failpoint.arm(phase, %{event_id: event_id}, self())

    spawn(fn ->
      Court.append(event(context, event_id, "vm_publication_reference", %{}, [ref]))
    end)

    await_cut(nonce, phase, cut, event_id)
  end

  defp cut_deletion_request(cut, context) do
    phase = Map.fetch!(@deletion_request_phases, cut)
    {:ok, ref} = Artifacts.publish("vm deletion request #{cut} #{Court.new_id()}")
    {:ok, _reference} = Court.append(event(context, Court.new_id(), "vm_deletion_target", %{}, [ref]))
    event_id = Court.new_id()
    nonce = Failpoint.arm(phase, %{event_id: event_id}, self())

    spawn(fn -> Artifacts.delete_requested(ref, Map.put(context, :event_id, event_id)) end)
    await_cut(nonce, phase, cut, ref)
  end

  defp cut_deletion(cut, context) do
    phase = Map.fetch!(@deletion_phases, cut)
    {:ok, ref} = Artifacts.publish("vm deletion #{cut} #{Court.new_id()}")
    {:ok, _reference} = Court.append(event(context, Court.new_id(), "vm_deletion_target", %{}, [ref]))
    {:ok, _request} = Artifacts.delete_requested(ref, context)
    nonce = Failpoint.arm(phase, %{ref: ref}, self())

    spawn(fn ->
      Artifacts.complete_deletion(ref, context, checkpoint: &Failpoint.hit/2)
    end)

    await_cut(nonce, phase, cut, ref)
  end

  defp cut_scheduler(cut, context) do
    phase = :court_append_committed_before_ack
    nonce = Failpoint.arm(phase, %{event_type: "resident_paused"}, self())
    spawn(fn -> Scheduler.Admission.pause(context) end)
    await_cut(nonce, phase, cut, :event_id_from_metadata)
  end

  defp await_cut(nonce, phase, cut, marker) do
    receive do
      {:court_failpoint, ^nonce, ^phase, metadata, _blocked_process} ->
        marker =
          if marker == :event_id_from_metadata, do: Map.fetch!(metadata, :event_id), else: marker

        encoded_nonce = nonce |> :erlang.term_to_binary() |> Base.url_encode64(padding: false)
        IO.puts("VOTP_READY\t#{System.pid()}\t#{cut}\t#{encoded_nonce}\t#{marker}")

        receive do
          {:never_continue, ^nonce} -> :ok
        end
    end
  end

  defp context(identity) do
    %{
      actor: "owner",
      resident_id: identity.resident_id,
      incarnation_id: identity.incarnation_id,
      authority: "owner",
      reason: "M1 whole-VM recovery test",
      retention_policy_version: 1
    }
  end

  defp event(context, event_id, event_type, payload, artifact_refs) do
    %{
      event_id: event_id,
      event_type: event_type,
      schema_version: 1,
      occurred_at: DateTime.utc_now(),
      actor: "worker/synthetic",
      resident_id: context.resident_id,
      incarnation_id: context.incarnation_id,
      payload: payload,
      artifact_refs: artifact_refs
    }
  end

  defp content_ref(content) do
    "sha256:" <> (:crypto.hash(:sha256, content) |> Base.encode16(case: :lower))
  end

  defp abort(message) do
    IO.puts(:stderr, "VOTP_DRIVER_ERROR\t#{message}")
    System.halt(2)
  end
end

Court.RecoveryVmDriver.main(System.argv())
