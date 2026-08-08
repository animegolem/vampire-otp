defmodule Court.Writer do
  @moduledoc """
  The single serialization point for all court appends.

  Producers never receive a Repo, Ecto schema, or changeset. This
  process normalizes, stamps, and commits one immutable envelope at a
  time.
  """

  use GenServer
  require Logger

  alias Court.{Error, Event, EventRecord, Repo}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put_new(options, :name, __MODULE__))
  end

  @spec append(map()) :: {:ok, Event.t()} | {:error, Error.t()}
  def append(attrs), do: GenServer.call(__MODULE__, {:append, attrs}, 30_000)

  @impl true
  def init(:ok), do: {:ok, %{}}

  @impl true
  def handle_call({:append, attrs}, _from, state) do
    {:reply, do_append(attrs), state}
  end

  defp do_append(attrs) do
    case Event.normalize(attrs) do
      {:ok, candidate} -> transact_append(candidate)
      {:error, details} -> {:error, invalid_event(details)}
    end
  rescue
    error ->
      {:error,
       %Error{
         code: :storage_error,
         message: "court append failed",
         details: %{exception: Exception.message(error)}
       }}
  end

  defp transact_append(candidate) do
    Repo.transact(fn -> append_normalized(candidate) end)
  end

  defp append_normalized(candidate) do
    case Repo.get_by(EventRecord, event_id: candidate.event_id) do
      nil -> insert(candidate)
      committed -> compare_retry(candidate, EventRecord.to_domain(committed))
    end
  end

  defp insert(candidate) do
    candidate
    |> EventRecord.changeset(DateTime.utc_now())
    |> Repo.insert()
    |> case do
      {:ok, record} -> {:ok, EventRecord.to_domain(record)}
      {:error, changeset} -> {:error, invalid_event(changeset_errors(changeset))}
    end
  end

  defp compare_retry(candidate, committed) do
    candidate_fingerprint = Event.producer_fingerprint(candidate)
    committed_fingerprint = Event.producer_fingerprint(committed)

    if candidate_fingerprint == committed_fingerprint do
      {:ok, committed}
    else
      Logger.warning("court event_id conflict",
        event_id: candidate.event_id,
        candidate_fingerprint: candidate_fingerprint,
        committed_fingerprint: committed_fingerprint
      )

      {:error,
       %Error{
         code: :event_id_conflict,
         message: "event_id is already committed with different producer fields",
         details: %{event_id: candidate.event_id}
       }}
    end
  end

  defp invalid_event(details),
    do: %Error{code: :invalid_event, message: "event envelope is invalid", details: details}

  defp changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, options} ->
      Enum.reduce(options, message, fn {key, value}, rendered ->
        String.replace(rendered, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
