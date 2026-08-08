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

  @doc false
  def ensure_resident_created(attrs),
    do: GenServer.call(__MODULE__, {:ensure_lifecycle, :resident_created, attrs}, 30_000)

  @doc false
  def ensure_incarnation_started(attrs),
    do: GenServer.call(__MODULE__, {:ensure_lifecycle, :incarnation_started, attrs}, 30_000)

  @doc false
  def ensure_incarnation_ended(attrs),
    do: GenServer.call(__MODULE__, {:ensure_lifecycle, :incarnation_ended, attrs}, 30_000)

  @doc false
  def infer_incarnation_crash(orphan_incarnation_id, attrs),
    do:
      GenServer.call(
        __MODULE__,
        {:infer_incarnation_crash, orphan_incarnation_id, attrs},
        30_000
      )

  @impl true
  def init(:ok) do
    migrations_path = Application.app_dir(:court, "priv/repo/migrations")
    Ecto.Migrator.run(Repo, migrations_path, :up, all: true, log: false)
    {:ok, %{}}
  end

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

  def handle_call({:ensure_lifecycle, kind, attrs}, _from, state) do
    {:reply, do_lifecycle_event(kind, attrs), state}
  end

  def handle_call({:infer_incarnation_crash, orphan_incarnation_id, attrs}, _from, state) do
    {:reply, do_crash_inference(orphan_incarnation_id, attrs), state}
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
    transact(candidate, fn -> append_normalized(candidate) end)
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
      transact(candidate, fn -> append_artifact_event(kind, ref, candidate) end)
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
    event_records(event_type)
    |> Enum.filter(&(get_in(&1.payload, ["artifact_ref"]) == ref))
    |> List.last()
  end

  defp do_lifecycle_event(kind, attrs) do
    with {:ok, candidate} <- normalize(attrs),
         :ok <- require_event_type(candidate, Atom.to_string(kind)) do
      transact(candidate, fn -> append_lifecycle_event(kind, candidate) end)
    end
  rescue
    error -> lifecycle_storage_error(error)
  end

  defp append_lifecycle_event(:resident_created, candidate) do
    case event_records("resident_created") do
      [] ->
        append_normalized(candidate)

      [existing] ->
        {:ok, existing}

      roots ->
        resident_ids = roots |> Enum.map(& &1.resident_id) |> Enum.uniq()

        if length(resident_ids) == 1 do
          {:ok, List.first(roots)}
        else
          lifecycle_error("court contains multiple resident roots", %{resident_ids: resident_ids})
        end
    end
  end

  defp append_lifecycle_event(:incarnation_started, candidate) do
    case event_for_incarnation("incarnation_started", candidate.incarnation_id) do
      nil ->
        with :ok <- require_resident_root(candidate.resident_id) do
          append_normalized(candidate)
        end

      existing ->
        {:ok, existing}
    end
  end

  defp append_lifecycle_event(:incarnation_ended, candidate) do
    start = event_for_incarnation("incarnation_started", candidate.incarnation_id)
    ended = event_for_incarnation("incarnation_ended", candidate.incarnation_id)

    cond do
      ended ->
        {:ok, ended}

      is_nil(start) ->
        lifecycle_error("incarnation ending has no committed start", %{
          incarnation_id: candidate.incarnation_id
        })

      true ->
        append_normalized(%{candidate | causation_id: start.event_id})
    end
  end

  defp do_crash_inference(orphan_incarnation_id, attrs) do
    with {:ok, candidate} <- normalize(attrs),
         :ok <- require_event_type(candidate, "incarnation_crash_inferred") do
      transact(candidate, fn -> append_crash_inference(orphan_incarnation_id, candidate) end)
    end
  rescue
    error -> lifecycle_storage_error(error)
  end

  defp append_crash_inference(orphan_incarnation_id, candidate) do
    start = event_for_incarnation("incarnation_started", orphan_incarnation_id)
    ended = event_for_incarnation("incarnation_ended", orphan_incarnation_id)

    inferred =
      event_records("incarnation_crash_inferred")
      |> Enum.find(&(get_in(&1.payload, ["orphan_incarnation_id"]) == orphan_incarnation_id))

    cond do
      inferred ->
        {:ok, inferred}

      is_nil(start) ->
        lifecycle_error("crash inference has no committed incarnation start", %{
          orphan_incarnation_id: orphan_incarnation_id
        })

      not is_nil(ended) or candidate.incarnation_id == orphan_incarnation_id ->
        {:ok, :not_orphan}

      true ->
        candidate = %{
          candidate
          | causation_id: start.event_id,
            payload: Map.put(candidate.payload, "orphan_incarnation_id", orphan_incarnation_id)
        }

        append_normalized(candidate)
    end
  end

  defp event_records(event_type) do
    Repo.all(
      from record in EventRecord,
        where: record.event_type == ^event_type,
        order_by: [asc: record.event_seq]
    )
    |> Enum.map(&EventRecord.to_domain/1)
  end

  defp event_for_incarnation(event_type, incarnation_id),
    do: Enum.find(event_records(event_type), &(&1.incarnation_id == incarnation_id))

  defp require_resident_root(resident_id) do
    case event_records("resident_created") do
      [%{resident_id: ^resident_id} | _] ->
        :ok

      _ ->
        lifecycle_error("incarnation does not belong to the resident root", %{
          resident_id: resident_id
        })
    end
  end

  defp require_event_type(%Event{event_type: expected}, expected), do: :ok

  defp require_event_type(%Event{event_type: actual}, expected),
    do:
      lifecycle_error("semantic command received the wrong event type", %{
        expected: expected,
        actual: actual
      })

  defp lifecycle_error(message, details),
    do: {:error, %Error{code: :invalid_lifecycle_state, message: message, details: details}}

  defp lifecycle_storage_error(error) do
    {:error,
     %Error{
       code: :storage_error,
       message: "lifecycle court transition failed",
       details: %{exception: Exception.message(error)}
     }}
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

  defp transact(candidate, operation) do
    result =
      Repo.transact(fn ->
        transaction_result = operation.()
        maybe_hit_failpoint(:court_append_before_commit, candidate, transaction_result)
        transaction_result
      end)

    maybe_hit_failpoint(:court_append_committed_before_ack, candidate, result)
    result
  end

  defp maybe_hit_failpoint(phase, candidate, {:ok, %Event{}}) do
    Court.Failpoint.hit(phase, %{event_id: candidate.event_id, event_type: candidate.event_type})
  end

  defp maybe_hit_failpoint(_phase, _candidate, _result), do: :ok

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
