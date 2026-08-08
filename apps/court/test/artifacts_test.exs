defmodule Court.ArtifactsTest do
  use ExUnit.Case, async: false

  alias Court.Artifacts
  alias Court.Artifacts.Resolution
  alias Court.Error

  defp context(overrides \\ %{}) do
    Map.merge(
      %{
        actor: "owner",
        resident_id: HumbleUlid.generate(),
        incarnation_id: HumbleUlid.generate(),
        authority: "owner",
        reason: "test retention request",
        retention_policy_version: 1
      },
      overrides
    )
  end

  defp event(ref, event_type \\ "artifact_reference_test") do
    %{
      event_id: HumbleUlid.generate(),
      event_type: event_type,
      schema_version: 1,
      occurred_at: DateTime.utc_now(),
      actor: "worker/test",
      resident_id: HumbleUlid.generate(),
      incarnation_id: HumbleUlid.generate(),
      payload: %{"purpose" => "artifact test"},
      artifact_refs: [ref]
    }
  end

  defp ref_for(content) do
    "sha256:" <> (:crypto.hash(:sha256, content) |> Base.encode16(case: :lower))
  end

  test "publication follows the durable order and content round-trips" do
    {:ok, phases} = Agent.start_link(fn -> [] end)
    content = "durable artifact #{System.unique_integer([:positive])}"

    checkpoint = fn phase, _metadata -> Agent.update(phases, &[phase | &1]) end

    assert {:ok, ref} = Artifacts.publish(content, checkpoint: checkpoint)
    assert ref == ref_for(content)
    assert {:ok, ^content} = Artifacts.read(ref)
    assert {:ok, %Resolution{state: :available, integrity_fault: false}} = Artifacts.resolve(ref)

    assert Agent.get(phases, &Enum.reverse/1) == [
             :staging_written,
             :file_synced,
             :renamed,
             :directory_synced
           ]

    assert {:ok, ^ref} = Artifacts.publish(content)
  end

  test "invalid refs cannot escape the configured store" do
    assert {:error, %Error{code: :invalid_artifact_ref}} = Artifacts.resolve("sha256:../../etc")

    assert {:error, %Error{code: :invalid_artifact_ref}} =
             Artifacts.resolve("md5:" <> String.duplicate("0", 32))
  end

  test "writer accepts only available artifact references" do
    content = "referenced artifact #{System.unique_integer([:positive])}"
    assert {:ok, ref} = Artifacts.publish(content)
    assert {:ok, committed} = Court.append(event(ref))
    assert committed.artifact_refs == [ref]

    assert {:ok, request} = Artifacts.delete_requested(ref, context())
    assert request.event_type == "artifact_deletion_requested"
    assert request.artifact_refs == []

    assert {:ok, %Resolution{state: :deletion_pending}} = Artifacts.resolve(ref)

    assert {:error, %Error{code: :artifact_unavailable}} =
             Court.append(event(ref, "pending_artifact_reference"))
  end

  test "two-phase deletion records the full authorizing chain" do
    content = "delete me #{System.unique_integer([:positive])}"
    assert {:ok, ref} = Artifacts.publish(content)
    deletion_context = context()

    assert {:ok, request} = Artifacts.delete_requested(ref, deletion_context)
    assert {:ok, same_request} = Artifacts.delete_requested(ref, deletion_context)
    assert same_request.event_id == request.event_id

    assert {:ok, tombstone} = Artifacts.complete_deletion(ref, deletion_context)
    assert tombstone.causation_id == request.event_id

    assert {:ok,
            %Resolution{
              state: :tombstoned,
              request_event_id: request_id,
              tombstone_event_id: tombstone_id,
              integrity_fault: false
            }} = Artifacts.resolve(ref)

    assert request_id == request.event_id
    assert tombstone_id == tombstone.event_id
    assert {:ok, :tombstoned} = Artifacts.recover(ref, deletion_context)
  end

  test "deletion recovery converges from every interrupted phase" do
    for phase <- [:bytes_deleted, :deletion_directory_synced] do
      content = "deletion cut #{phase} #{System.unique_integer([:positive])}"
      assert {:ok, ref} = Artifacts.publish(content)
      deletion_context = context()
      assert {:ok, request} = Artifacts.delete_requested(ref, deletion_context)

      assert catch_throw(
               Artifacts.complete_deletion(ref, deletion_context,
                 checkpoint: fn reached, _metadata ->
                   if reached == phase, do: throw({:simulated_crash, phase})
                 end
               )
             ) == {:simulated_crash, phase}

      assert {:ok,
              %Resolution{
                state: :deletion_pending,
                request_event_id: request_id,
                tombstone_event_id: nil
              }} = Artifacts.resolve(ref)

      assert request_id == request.event_id
      assert {:ok, tombstone} = Artifacts.recover(ref, deletion_context)
      assert tombstone.event_type == "artifact_tombstoned"
      assert {:ok, %Resolution{state: :tombstoned}} = Artifacts.resolve(ref)
    end
  end

  test "a committed tombstone survives a lost acknowledgement" do
    content = "tombstone ack cut #{System.unique_integer([:positive])}"
    assert {:ok, ref} = Artifacts.publish(content)
    deletion_context = context()
    assert {:ok, _request} = Artifacts.delete_requested(ref, deletion_context)

    assert catch_throw(
             Artifacts.complete_deletion(ref, deletion_context,
               checkpoint: fn phase, _metadata ->
                 if phase == :tombstone_committed, do: throw(:lost_ack)
               end
             )
           ) == :lost_ack

    assert {:ok, %Resolution{state: :tombstoned}} = Artifacts.resolve(ref)
    assert {:ok, :tombstoned} = Artifacts.recover(ref, deletion_context)
  end

  test "missing bytes without authorization surface an integrity fault" do
    ref = "sha256:" <> String.duplicate("0", 64)

    assert {:ok, %Resolution{state: :missing, integrity_fault: true}} = Artifacts.resolve(ref)

    assert {:error, %Error{code: :integrity_fault}} =
             Court.append(event(ref, "missing_artifact_reference"))

    assert {:error, %Error{code: :integrity_fault}} = Artifacts.recover(ref, context())
  end

  test "publication cuts never execute the referencing append" do
    for phase <- [:staging_written, :file_synced, :renamed, :directory_synced] do
      content = "publication cut #{phase} #{System.unique_integer([:positive])}"
      ref = ref_for(content)
      event_type = "publication_cut_#{System.unique_integer([:positive])}"

      assert catch_throw(
               with {:ok, ^ref} <-
                      Artifacts.publish(content,
                        checkpoint: fn reached, _metadata ->
                          if reached == phase, do: throw({:simulated_crash, phase})
                        end
                      ),
                    {:ok, committed} <- Court.append(event(ref, event_type)) do
                 committed
               end
             ) == {:simulated_crash, phase}

      assert {:ok, []} = Court.by_type(event_type)
    end
  end
end
