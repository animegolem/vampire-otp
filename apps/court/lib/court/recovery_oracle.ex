defmodule Court.RecoveryOracle do
  @moduledoc """
  I/O boundary that reconciles the pure replay with artifact bytes.

  The returned `derived` value is produced only by `Court.Replay`.
  Artifact resolution is evidence beside that state, never a second
  authoritative store.
  """

  alias Court.{Artifacts, Error, Replay}

  @spec inspect_prefix() :: {:ok, map()} | {:error, Error.t()}
  def inspect_prefix do
    maximum = Court.max_event_seq()

    with {:ok, events} <- read_prefix(maximum),
         {:ok, derived} <- Replay.fold(events),
         {:ok, resolutions, recovery_actions} <- resolve_artifacts(derived.artifacts) do
      {:ok,
       %{
         maximum_event_seq: maximum,
         events: events,
         derived: derived,
         artifact_resolutions: resolutions,
         artifact_recovery: recovery_actions
       }}
    end
  end

  defp read_prefix(0), do: {:ok, []}
  defp read_prefix(maximum), do: Court.by_seq_range(1, maximum)

  defp resolve_artifacts(artifacts) do
    Enum.reduce_while(artifacts, {:ok, %{}, %{}}, fn
      {ref, expected}, {:ok, resolved, actions} ->
        case Artifacts.resolve(ref) do
          {:ok, resolution} ->
            with :ok <- validate_resolution(expected, resolution),
                 {:ok, recovery_action} <- recovery_action(ref, resolution) do
              {:cont,
               {:ok, Map.put(resolved, ref, resolution), Map.put(actions, ref, recovery_action)}}
            else
              {:error, %Error{} = error} -> {:halt, {:error, error}}
            end

          {:error, %Error{} = error} ->
            {:halt, {:error, error}}
        end
    end)
  end

  defp recovery_action(_ref, %{state: state}) when state in [:available, :tombstoned],
    do: {:ok, :none}

  defp recovery_action(ref, %{state: :deletion_pending}) do
    with {:ok, path} <- Artifacts.storage_path(ref) do
      if File.regular?(path) do
        {:ok, :delete_then_tombstone}
      else
        {:ok, :commit_tombstone}
      end
    end
  end

  defp validate_resolution(expected, resolution) do
    cond do
      resolution.integrity_fault ->
        integrity_fault(expected, resolution)

      resolution.state == :deletion_pending and is_nil(resolution.request_event_id) ->
        integrity_fault(expected, resolution)

      resolution.state != expected.expected_state ->
        integrity_fault(expected, resolution)

      resolution.state in [:available, :tombstoned, :deletion_pending] ->
        :ok

      true ->
        integrity_fault(expected, resolution)
    end
  end

  defp integrity_fault(expected, resolution) do
    {:error,
     %Error{
       code: :integrity_fault,
       message: "artifact reference does not satisfy the recovery oracle",
       details: %{expected: expected, resolution: resolution}
     }}
  end
end
