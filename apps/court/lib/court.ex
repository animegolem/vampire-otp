defmodule Court do
  @moduledoc """
  Typed public boundary for the append-only event court.

  Corrections are new events linked by `causation_id`. This API exposes
  no update or delete operation, Ecto query, changeset, or schema.
  """

  import Ecto.Query

  alias Court.{Error, Event, EventRecord, Repo, Writer}

  @spec append(map()) :: {:ok, Event.t()} | {:error, Error.t()}
  defdelegate append(event), to: Writer

  @spec by_seq_range(pos_integer(), pos_integer() | nil) :: {:ok, [Event.t()]}
  def by_seq_range(first, last \\ nil)

  def by_seq_range(first, last) when is_integer(first) and first > 0 do
    if is_nil(last) or (is_integer(last) and last >= first) do
      query = from event in EventRecord, where: event.event_seq >= ^first
      query = if last, do: from(event in query, where: event.event_seq <= ^last), else: query

      {:ok,
       query
       |> order_by([event], asc: event.event_seq)
       |> Repo.all()
       |> Enum.map(&EventRecord.to_domain/1)}
    else
      invalid_query("sequence range is invalid")
    end
  end

  def by_seq_range(_first, _last), do: invalid_query("sequence range is invalid")

  @spec by_event_id(String.t()) :: {:ok, Event.t()} | {:error, Error.t()}
  def by_event_id(event_id) when is_binary(event_id) do
    case Repo.get_by(EventRecord, event_id: event_id) do
      nil ->
        {:error,
         %Error{code: :not_found, message: "event not found", details: %{event_id: event_id}}}

      record ->
        {:ok, EventRecord.to_domain(record)}
    end
  end

  def by_event_id(_event_id), do: invalid_query("event_id query must be a string")

  @spec by_type(String.t()) :: {:ok, [Event.t()]}
  def by_type(event_type) when is_binary(event_type) do
    events =
      Repo.all(
        from event in EventRecord,
          where: event.event_type == ^event_type,
          order_by: [asc: event.event_seq]
      )

    {:ok, Enum.map(events, &EventRecord.to_domain/1)}
  end

  def by_type(_event_type), do: invalid_query("event_type query must be a string")

  @spec max_event_seq() :: non_neg_integer()
  def max_event_seq do
    Repo.one(from event in EventRecord, select: max(event.event_seq)) || 0
  end

  defp invalid_query(message),
    do: {:error, %Error{code: :invalid_query, message: message}}
end
