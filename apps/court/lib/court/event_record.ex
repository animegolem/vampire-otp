defmodule Court.EventRecord do
  @moduledoc false

  use Ecto.Schema

  alias Court.Event

  @primary_key {:event_seq, :id, autogenerate: true}

  schema "events" do
    field :event_id, :string
    field :event_type, :string
    field :schema_version, :integer
    field :occurred_at, :utc_datetime_usec
    field :recorded_at, :utc_datetime_usec
    field :actor, :string
    field :causation_id, :string
    field :correlation_id, :string
    field :resident_id, :string
    field :incarnation_id, :string
    field :session_id, :string
    field :episode_id, :string
    field :segment_id, :string
    field :window_id, :string
    field :tick_id, :string
    field :turn_id, :string
    field :payload, :map, default: %{}
    field :artifact_refs, {:array, :string}, default: []
  end

  @fields [
    :event_id,
    :event_type,
    :schema_version,
    :occurred_at,
    :recorded_at,
    :actor,
    :causation_id,
    :correlation_id,
    :resident_id,
    :incarnation_id,
    :session_id,
    :episode_id,
    :segment_id,
    :window_id,
    :tick_id,
    :turn_id,
    :payload,
    :artifact_refs
  ]

  @spec changeset(Event.t(), DateTime.t()) :: Ecto.Changeset.t()
  def changeset(%Event{} = event, recorded_at) do
    attrs =
      event
      |> Map.from_struct()
      |> Map.take(@fields)
      |> Map.put(:recorded_at, recorded_at)

    Ecto.Changeset.cast(%__MODULE__{}, attrs, @fields)
  end

  @spec to_domain(%__MODULE__{}) :: Event.t()
  def to_domain(%__MODULE__{} = record) do
    struct!(Event, Map.take(record, [:event_seq | @fields]))
  end
end
