defmodule Court.Writer do
  @moduledoc """
  The single serialization point for all court appends.

  Producers never receive a Repo, Ecto schema, or changeset. This
  process normalizes, stamps, and commits one immutable envelope at a
  time.
  """

  use GenServer
  import Ecto.Query
  require Logger

  alias Court.{Artifacts, Error, Event, EventRecord, Repo}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put_new(options, :name, __MODULE__))
  end

  @spec append(map()) :: {:ok, Event.t()} | {:error, Error.t()}
  def append(attrs), do: GenServer.call(__MODULE__, {:append, attrs}, 30_000)

  @doc false
  @spec request_artifact_deletion(String.t(), map()) ::
          {:ok, Event.t()} | {:error, Error.t()}
  def request_artifact_deletion(ref, attrs),
    do: GenServer.call(__MODULE__, {:request_artifact_deletion, ref, attrs}, 30_000)

  @doc false
  @spec complete_artifact_deletion(String.t(), map()) ::
          {:ok, Event.t()} | {:error, Error.t()}
  def complete_artifact_deletion(ref, attrs),
    do: GenServer.call(__MODULE__, {:complete_artifact_deletion, ref, attrs}, 30_000)

  @impl true
  def init(:ok), do: {:ok, %{}}

  @impl true
  def handle_call({:append, attrs}, _from, state) do
    {:reply, do_append(attrs), state}
  end

  def handle_call({:request_artifact_deletion, ref, attrs}, _from, state) do
    {:reply, do_artifact_event(:request, ref, attrs), state}
  end

  def handle_call({:complete_artifact_deletion, ref, attrs}, _from, state) do
    {:reply, do_artifact_event(:tombstone, ref, attrs), state}
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
    with :ok <- Artifacts.ensure_refs_available(candidate.artifact_refs) do
      case Repo.get_by(EventRecord, event_id: candidate.event_id) do
        nil -> insert(candidate)
        committed -> compare_retry(candidate, EventRecord.to_domain(committed))
      end
    end
  end

  defp do_artifact_event(kind, ref, attrs) do
    with {:ok, candidate} <- normalize(attrs) do
      Repo.transact(fn -> append_artifact_event(kind, ref, candidate) end)
    end
  rescue
    error ->
      {:error,
       %Error{
         code: :storage_error,
         message: "artifact court transition failed",
         details: %{exception: Exception.message(error)}
       }}
  end

  defp append_artifact_event(:request, ref, candidate) do
    case latest_artifact_event("artifact_deletion_requested", ref) do
      nil -> append_normalized(candidate)
      existing -> {:ok, existing}
    end
  end

  defp append_artifact_event(:tombstone, ref, candidate) do
    request = latest_artifact_event("artifact_deletion_requested", ref)
    tombstone = latest_artifact_event("artifact_tombstoned", ref)

    cond do
      tombstone ->
        {:ok, tombstone}

      is_nil(request) ->
        {:error,
         %Error{
           code: :invalid_artifact_state,
           message: "artifact tombstone requires an authorizing deletion request",
           details: %{artifact_ref: ref}
         }}

      true ->
        append_normalized(%{candidate | causation_id: request.event_id})
    end
  end

  defp latest_artifact_event(event_type, ref) do
    Repo.all(
      from record in EventRecord,
        where: record.event_type == ^event_type,
        order_by: [asc: record.event_seq]
    )
    |> Enum.map(&EventRecord.to_domain/1)
    |> Enum.filter(&(get_in(&1.payload, ["artifact_ref"]) == ref))
    |> List.last()
  end

  defp normalize(attrs) do
    case Event.normalize(attrs) do
      {:ok, candidate} -> {:ok, candidate}
      {:error, details} -> {:error, invalid_event(details)}
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
