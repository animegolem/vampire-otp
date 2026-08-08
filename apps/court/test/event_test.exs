defmodule Court.EventTest do
  use ExUnit.Case, async: false

  alias Court.Error

  defp event(overrides \\ %{}) do
    Map.merge(
      %{
        event_id: HumbleUlid.generate(),
        event_type: "test_observed",
        schema_version: 1,
        occurred_at: DateTime.utc_now(),
        actor: "worker/test",
        resident_id: HumbleUlid.generate(),
        incarnation_id: HumbleUlid.generate(),
        payload: %{"value" => 1},
        artifact_refs: []
      },
      overrides
    )
  end

  test "validates the complete envelope and closed actor roster" do
    assert {:error, %Error{code: :invalid_event, details: details}} =
             Court.append(event(%{actor: "scheduelr", resident_id: nil}))

    assert %{actor: [_], resident_id: [_]} = details

    assert {:ok, committed} = Court.append(event(%{actor: "scheduler/m1"}))
    assert committed.recorded_at
    assert committed.event_seq > 0
  end

  test "round-trips every A.1 field as a plain domain value" do
    causation_id = HumbleUlid.generate()

    attrs =
      event(%{
        causation_id: causation_id,
        correlation_id: "batch/alpha",
        session_id: "session-1",
        episode_id: "episode-1",
        segment_id: "segment-1",
        window_id: "window-1",
        tick_id: "tick-1",
        turn_id: "turn-1",
        payload: %{nested: [%{"truth" => true}, nil]},
        artifact_refs: ["sha256:abcd"]
      })

    assert {:ok, committed} = Court.append(attrs)
    refute Map.has_key?(committed, :__meta__)
    assert committed.causation_id == causation_id
    assert committed.correlation_id == "batch/alpha"
    assert committed.session_id == "session-1"
    assert committed.episode_id == "episode-1"
    assert committed.segment_id == "segment-1"
    assert committed.window_id == "window-1"
    assert committed.tick_id == "tick-1"
    assert committed.turn_id == "turn-1"
    assert committed.payload == %{"nested" => [%{"truth" => true}, nil]}
    assert committed.artifact_refs == ["sha256:abcd"]
  end

  test "rejects malformed fields and producer attempts to assign court fields" do
    invalid =
      event(%{
        event_id: String.downcase(HumbleUlid.generate()),
        event_seq: 12,
        recorded_at: DateTime.utc_now(),
        payload: %{"bad" => self()},
        artifact_refs: ["not-qualified"]
      })

    assert {:error, %Error{code: :invalid_event, details: details}} = Court.append(invalid)
    assert Map.has_key?(details, :event_id)
    assert Map.has_key?(details, :event_seq)
    assert Map.has_key?(details, :recorded_at)
    assert Map.has_key?(details, :payload)
    assert Map.has_key?(details, :artifact_refs)
  end

  test "identical retries return the committed row and conflicts are typed" do
    attrs = event(%{payload: %{same: "meaning"}})

    assert {:ok, first} = Court.append(attrs)
    assert {:ok, retried} = Court.append(attrs)
    assert first.event_seq == retried.event_seq

    assert {:error, %Error{code: :event_id_conflict}} =
             Court.append(%{attrs | payload: %{"same" => "different"}})
  end

  @tag timeout: 120_000
  test "20 concurrent producers append a gapless monotonic sequence" do
    baseline = Court.max_event_seq()
    resident_id = HumbleUlid.generate()
    incarnation_id = HumbleUlid.generate()

    results =
      1..20
      |> Task.async_stream(
        fn producer ->
          Enum.map(1..50, fn item ->
            Court.append(
              event(%{
                resident_id: resident_id,
                incarnation_id: incarnation_id,
                payload: %{"producer" => producer, "item" => item}
              })
            )
          end)
        end,
        max_concurrency: 20,
        ordered: false,
        timeout: 120_000
      )
      |> Enum.flat_map(fn {:ok, producer_results} -> producer_results end)

    assert Enum.all?(results, &match?({:ok, _}, &1))

    sequences =
      results
      |> Enum.map(fn {:ok, committed} -> committed.event_seq end)
      |> Enum.sort()

    assert sequences == Enum.to_list((baseline + 1)..(baseline + 1000))
    assert length(Enum.uniq(sequences)) == 1000
  end

  test "SQLite rejects raw updates and deletes of committed rows" do
    assert {:ok, committed} = Court.append(event())

    assert_raise Exqlite.Error, ~r/append-only: UPDATE rejected/, fn ->
      Ecto.Adapters.SQL.query!(
        Court.Repo,
        "UPDATE events SET event_type = 'tampered' WHERE event_seq = ?",
        [committed.event_seq]
      )
    end

    assert_raise Exqlite.Error, ~r/append-only: DELETE rejected/, fn ->
      Ecto.Adapters.SQL.query!(Court.Repo, "DELETE FROM events WHERE event_seq = ?", [
        committed.event_seq
      ])
    end
  end

  test "typed reads preserve court order" do
    event_type = "typed_read_#{System.unique_integer([:positive])}"
    assert {:ok, first} = Court.append(event(%{event_type: event_type}))
    assert {:ok, second} = Court.append(event(%{event_type: event_type}))

    assert {:ok, ^first} = Court.by_event_id(first.event_id)
    assert {:ok, [^first, ^second]} = Court.by_type(event_type)
    assert {:ok, [^first, ^second]} = Court.by_seq_range(first.event_seq, second.event_seq)
    assert {:error, %Error{code: :invalid_query}} = Court.by_seq_range(0, -1)
  end
end
