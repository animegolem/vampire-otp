defmodule Runtime.Projections.Registry do
  @moduledoc false

  alias Runtime.Lifecycle.Identity

  @projection_type "logs.txt"
  @schema_version 1

  @spec definition(String.t()) :: map()
  def definition(version) do
    base = %{
      "projection_type" => @projection_type,
      "schema_version" => @schema_version,
      "version" => version,
      "producer" => %{
        "kind" => "pure_code",
        "module" => "Runtime.Projections.Logs",
        "version" => version,
        "request_ref" => nil,
        "model_ref" => nil,
        "prompt_ref" => nil
      }
    }

    Map.put(base, "definition_digest", digest(base))
  end

  @spec active() :: {:ok, Court.Event.t() | nil}
  def active do
    with {:ok, created} <- Court.by_type("projection_created"),
         {:ok, superseded} <- Court.by_type("projection_superseded") do
      superseded_ids = MapSet.new(superseded, &get_in(&1.payload, ["superseded_projection_id"]))

      active =
        created
        |> Enum.filter(&(get_in(&1.payload, ["projection_type"]) == @projection_type))
        |> Enum.reject(&MapSet.member?(superseded_ids, get_in(&1.payload, ["projection_id"])))
        |> List.last()

      {:ok, active}
    end
  end

  @spec record_created(map(), Identity.t()) :: {:ok, Court.Event.t()} | {:error, Court.Error.t()}
  def record_created(descriptor, %Identity{} = identity) do
    Court.append(
      event("projection_created", descriptor, identity,
        artifact_refs: [descriptor["content_ref"]]
      )
    )
  end

  @spec record_superseded(Court.Event.t(), Court.Event.t(), Identity.t()) ::
          {:ok, Court.Event.t()} | {:error, Court.Error.t()}
  def record_superseded(prior, replacement, %Identity{} = identity) do
    payload = %{
      "projection_type" => @projection_type,
      "superseded_projection_id" => get_in(prior.payload, ["projection_id"]),
      "replacement_projection_id" => get_in(replacement.payload, ["projection_id"])
    }

    Court.append(
      event("projection_superseded", payload, identity, causation_id: replacement.event_id)
    )
  end

  @spec same_definition?(Court.Event.t(), map()) :: boolean()
  def same_definition?(event, definition),
    do: get_in(event.payload, ["definition_digest"]) == definition["definition_digest"]

  defp event(event_type, payload, identity, options) do
    %{
      event_id: Court.new_id(),
      event_type: event_type,
      schema_version: 1,
      occurred_at: DateTime.utc_now(),
      actor: "worker/projection",
      causation_id: Keyword.get(options, :causation_id),
      resident_id: identity.resident_id,
      incarnation_id: identity.incarnation_id,
      payload: payload,
      artifact_refs: Keyword.get(options, :artifact_refs, [])
    }
  end

  defp digest(value) do
    value
    |> Court.Event.canonicalize()
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
