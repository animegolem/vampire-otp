defmodule Court.Artifacts do
  @moduledoc """
  Durable content-addressed storage subordinated to the event court.

  Publication does not return until the staging file, final rename, and
  containing directory have been synced. Deletion is authorized and
  recorded through ordinary court events before bytes are removed.
  """

  alias Court.Artifacts.{Ref, Resolution}
  alias Court.{Error, Writer}

  @spec publish(iodata(), keyword()) :: {:ok, String.t()} | {:error, Error.t()}
  def publish(content, options \\ []) do
    bytes = IO.iodata_to_binary(content)
    ref = "sha256:" <> (:crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower))
    checkpoint = Keyword.get(options, :checkpoint, fn _phase, _metadata -> :ok end)

    with {:ok, path} <- storage_path(ref),
         :ok <- ensure_parent(path),
         result <- publish_at(ref, path, bytes, checkpoint) do
      result
    end
  rescue
    error -> artifact_io("artifact publication failed", error)
  catch
    kind, reason -> :erlang.raise(kind, reason, __STACKTRACE__)
  end

  @spec read(String.t()) :: {:ok, binary()} | {:error, Error.t()}
  def read(ref) do
    with {:ok, %Resolution{state: :available}} <- resolve(ref),
         {:ok, path} <- storage_path(ref),
         {:ok, bytes} <- File.read(path) do
      {:ok, bytes}
    else
      {:ok, %Resolution{} = resolution} -> unavailable(resolution)
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} -> artifact_io("artifact read failed", reason)
    end
  end

  @spec resolve(String.t()) :: {:ok, Resolution.t()} | {:error, Error.t()}
  def resolve(ref) do
    with {:ok, path} <- storage_path(ref),
         {:ok, requests} <- artifact_events("artifact_deletion_requested", ref),
         {:ok, tombstones} <- artifact_events("artifact_tombstoned", ref) do
      bytes_present = File.regular?(path)
      request = List.last(requests)
      tombstone = List.last(tombstones)

      {:ok, resolution(ref, bytes_present, request, tombstone)}
    end
  end

  @spec ensure_refs_available([String.t()]) :: :ok | {:error, Error.t()}
  def ensure_refs_available(refs) do
    refs
    |> Enum.uniq()
    |> Enum.reduce_while(:ok, fn ref, :ok ->
      case resolve(ref) do
        {:ok, %Resolution{state: :available, integrity_fault: false}} -> {:cont, :ok}
        {:ok, %Resolution{} = resolution} -> {:halt, unavailable(resolution)}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
  end

  @spec delete_requested(String.t(), map()) :: {:ok, Court.Event.t()} | {:error, Error.t()}
  def delete_requested(ref, context) do
    with :ok <- validate_deletion_context(context),
         {:ok, %Resolution{} = resolution} <- resolve(ref),
         :ok <- require_requestable(resolution),
         attrs <- deletion_event(context, "artifact_deletion_requested", ref),
         {:ok, event} <- Writer.request_artifact_deletion(ref, attrs) do
      {:ok, event}
    else
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  @spec complete_deletion(String.t(), map(), keyword()) ::
          {:ok, Court.Event.t()} | {:error, Error.t()}
  def complete_deletion(ref, context, options \\ []) do
    checkpoint = Keyword.get(options, :checkpoint, fn _phase, _metadata -> :ok end)

    with :ok <- validate_deletion_context(context),
         {:ok, %Resolution{} = before} <- resolve(ref),
         :ok <- require_deletion_pending(before),
         {:ok, path} <- storage_path(ref),
         _ <- checkpoint.(:deletion_before_unlink, %{ref: ref, path: path}),
         :ok <- remove_bytes(path),
         _ <- checkpoint.(:bytes_deleted, %{ref: ref, path: path}),
         :ok <- sync_directory(Path.dirname(path)),
         _ <- checkpoint.(:deletion_directory_synced, %{ref: ref, path: path}),
         attrs <- deletion_event(context, "artifact_tombstoned", ref),
         {:ok, event} <- Writer.complete_artifact_deletion(ref, attrs),
         _ <- checkpoint.(:tombstone_committed, %{ref: ref, event_id: event.event_id}) do
      {:ok, event}
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} -> artifact_io("artifact deletion failed", reason)
    end
  rescue
    error -> artifact_io("artifact deletion failed", error)
  catch
    kind, reason -> :erlang.raise(kind, reason, __STACKTRACE__)
  end

  @spec recover(String.t(), map()) ::
          {:ok, :available | :tombstoned | Court.Event.t()} | {:error, Error.t()}
  def recover(ref, context) do
    case resolve(ref) do
      {:ok, %Resolution{state: :deletion_pending}} -> complete_deletion(ref, context)
      {:ok, %Resolution{state: :tombstoned, integrity_fault: false}} -> {:ok, :tombstoned}
      {:ok, %Resolution{state: :available, integrity_fault: false}} -> {:ok, :available}
      {:ok, %Resolution{} = resolution} -> unavailable(resolution)
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  @doc false
  @spec storage_path(String.t()) :: {:ok, String.t()} | {:error, Error.t()}
  def storage_path(ref), do: Ref.path(ref, root())

  defp publish_at(ref, path, bytes, checkpoint) do
    if File.regular?(path) do
      with {:ok, ^ref} <- verify_existing(ref, path),
           :ok <- sync_directory(Path.dirname(path)),
           _ <- checkpoint.(:directory_synced, %{ref: ref, path: path}) do
        {:ok, ref}
      end
    else
      staging = path <> ".#{System.unique_integer([:positive, :monotonic])}.tmp"

      with {:ok, file} <-
             :file.open(String.to_charlist(staging), [:write, :binary, :raw, :exclusive]),
           :ok <- :file.write(file, bytes),
           _ <- checkpoint.(:staging_written, %{ref: ref, path: staging}),
           :ok <- :file.sync(file),
           _ <- checkpoint.(:file_synced, %{ref: ref, path: staging}),
           :ok <- :file.close(file),
           :ok <- :file.rename(String.to_charlist(staging), String.to_charlist(path)),
           _ <- checkpoint.(:renamed, %{ref: ref, path: path}),
           :ok <- sync_directory(Path.dirname(path)),
           _ <- checkpoint.(:directory_synced, %{ref: ref, path: path}) do
        {:ok, ref}
      else
        {:error, reason} -> artifact_io("artifact publication failed", reason)
      end
    end
  end

  defp verify_existing(ref, path) do
    with {:ok, bytes} <- File.read(path) do
      actual = "sha256:" <> (:crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower))

      if actual == ref do
        {:ok, ref}
      else
        {:error,
         %Error{
           code: :integrity_fault,
           message: "artifact bytes do not match their content address",
           details: %{expected: ref, actual: actual}
         }}
      end
    else
      {:error, reason} -> artifact_io("artifact verification failed", reason)
    end
  end

  defp ensure_parent(path) do
    root = root()
    algorithm_dir = Path.join(root, "sha256")
    shard_dir = Path.dirname(path)

    Enum.reduce_while([root, algorithm_dir, shard_dir], :ok, fn directory, :ok ->
      case File.mkdir(directory) do
        :ok ->
          case sync_directory(Path.dirname(directory)) do
            :ok -> {:cont, :ok}
            error -> {:halt, error}
          end

        {:error, :eexist} ->
          {:cont, :ok}

        {:error, reason} ->
          {:halt, artifact_io("artifact directory creation failed", reason)}
      end
    end)
  end

  defp sync_directory(path) do
    with {:ok, directory} <- :file.open(String.to_charlist(path), [:read, :raw, :directory]),
         :ok <- :file.sync(directory),
         :ok <- :file.close(directory) do
      :ok
    end
  end

  defp remove_bytes(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      error -> error
    end
  end

  defp artifact_events(event_type, ref) do
    with {:ok, events} <- Court.by_type(event_type) do
      {:ok, Enum.filter(events, &(get_in(&1.payload, ["artifact_ref"]) == ref))}
    end
  end

  defp resolution(ref, bytes_present, request, tombstone) do
    cond do
      tombstone && bytes_present ->
        %Resolution{
          ref: ref,
          state: :tombstoned,
          request_event_id: request && request.event_id,
          tombstone_event_id: tombstone.event_id,
          integrity_fault: true
        }

      tombstone ->
        %Resolution{
          ref: ref,
          state: :tombstoned,
          request_event_id: request && request.event_id,
          tombstone_event_id: tombstone.event_id
        }

      request ->
        %Resolution{ref: ref, state: :deletion_pending, request_event_id: request.event_id}

      bytes_present ->
        %Resolution{ref: ref, state: :available}

      true ->
        %Resolution{ref: ref, state: :missing, integrity_fault: true}
    end
  end

  defp require_deletion_pending(%Resolution{state: :deletion_pending}), do: :ok

  defp require_deletion_pending(resolution) do
    {:error,
     %Error{
       code: :invalid_artifact_state,
       message: "artifact deletion has no pending authorizing request",
       details: %{resolution: resolution}
     }}
  end

  defp require_requestable(%Resolution{state: state, integrity_fault: false})
       when state in [:available, :deletion_pending],
       do: :ok

  defp require_requestable(resolution), do: unavailable(resolution)

  defp validate_deletion_context(context) when is_map(context) do
    required = [
      :actor,
      :resident_id,
      :incarnation_id,
      :authority,
      :reason,
      :retention_policy_version
    ]

    missing = Enum.filter(required, &(is_nil(Map.get(context, &1)) or Map.get(context, &1) == ""))

    if missing == [] do
      :ok
    else
      {:error,
       %Error{
         code: :invalid_event,
         message: "artifact deletion context is incomplete",
         details: %{missing: missing}
       }}
    end
  end

  defp validate_deletion_context(_context) do
    {:error, %Error{code: :invalid_event, message: "artifact deletion context must be a map"}}
  end

  defp deletion_event(context, event_type, ref) do
    context
    |> Map.take([
      :event_id,
      :occurred_at,
      :actor,
      :correlation_id,
      :resident_id,
      :incarnation_id,
      :session_id,
      :episode_id,
      :segment_id,
      :window_id,
      :tick_id,
      :turn_id
    ])
    |> Map.put_new(:event_id, HumbleUlid.generate())
    |> Map.put_new(:occurred_at, DateTime.utc_now())
    |> Map.put(:event_type, event_type)
    |> Map.put(:schema_version, 1)
    |> Map.put(:artifact_refs, [])
    |> Map.put(:payload, %{
      "artifact_ref" => ref,
      "authority" => Map.get(context, :authority),
      "reason" => Map.get(context, :reason),
      "retention_policy_version" => Map.get(context, :retention_policy_version)
    })
  end

  defp unavailable(%Resolution{} = resolution) do
    code = if resolution.integrity_fault, do: :integrity_fault, else: :artifact_unavailable

    {:error,
     %Error{
       code: code,
       message: "artifact is not available",
       details: %{resolution: resolution}
     }}
  end

  defp artifact_io(message, reason) do
    {:error,
     %Error{
       code: :artifact_io,
       message: message,
       details: %{reason: inspect(reason)}
     }}
  end

  defp root do
    :court
    |> Application.fetch_env!(__MODULE__)
    |> Keyword.fetch!(:root)
  end
end
