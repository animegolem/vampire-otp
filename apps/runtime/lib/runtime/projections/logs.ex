defmodule Runtime.Projections.Logs do
  @moduledoc """
  Deterministic, human-readable projection of the court.

  Every complete line begins with its `event_seq`; the file tail is the
  cursor. Registry events name explicit source prefixes, so rebuilding
  never consumes the registry event produced by the build itself.
  """

  use GenServer

  alias Court.Artifacts
  alias Runtime.{ProjectionError, Projections.Cursor, Projections.Registry}

  @default_version "1"

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) do
    name = Keyword.get(options, :name, __MODULE__)
    genserver_options = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, options, genserver_options)
  end

  @spec build(keyword()) :: {:ok, map()} | {:error, term()}
  def build(options \\ []), do: GenServer.call(__MODULE__, {:build, options}, 120_000)

  @spec rebuild(keyword()) :: {:ok, map()} | {:error, term()}
  def rebuild(options \\ []), do: GenServer.call(__MODULE__, {:rebuild, options}, 120_000)

  @spec catch_up(keyword()) :: {:ok, map()} | {:error, term()}
  def catch_up(options \\ []), do: GenServer.call(__MODULE__, {:catch_up, options}, 120_000)

  @spec render(Court.Event.t()) :: binary()
  def render(%Court.Event{} = event) do
    fields = [
      Integer.to_string(event.event_seq),
      DateTime.to_iso8601(event.recorded_at),
      event.event_type,
      event.actor,
      "resident=" <> inspect(event.resident_id),
      "incarnation=" <> inspect(event.incarnation_id),
      "payload=" <>
        inspect(Court.Event.canonicalize(event.payload),
          limit: :infinity,
          printable_limit: :infinity,
          width: :infinity
        ),
      "artifacts=" <>
        inspect(event.artifact_refs,
          limit: :infinity,
          printable_limit: :infinity,
          width: :infinity
        )
    ]

    Enum.join(fields, "\t") <> "\n"
  end

  @impl true
  def init(options) do
    {:ok, %{path: Keyword.get(options, :path, configured_path())}}
  end

  @impl true
  def handle_call({:build, options}, _from, state) do
    version = Keyword.get(options, :version, @default_version)
    definition = Registry.definition(version)

    result =
      with {:ok, active} <- Registry.active() do
        cond do
          is_nil(active) ->
            materialize_definition(state.path, definition, nil)

          Registry.same_definition?(active, definition) ->
            catch_up_to(state.path, Court.max_event_seq(), options)

          true ->
            materialize_definition(state.path, definition, active)
        end
      end

    {:reply, result, state}
  end

  def handle_call({:rebuild, options}, _from, state) do
    version = Keyword.get(options, :version, @default_version)
    definition = Registry.definition(version)

    result =
      with {:ok, active} <- Registry.active() do
        cond do
          is_nil(active) ->
            {:error,
             %ProjectionError{code: :not_built, message: "logs projection has no registry entry"}}

          Registry.same_definition?(active, definition) ->
            rebuild_same_definition(state.path, active)

          true ->
            materialize_definition(state.path, definition, active)
        end
      end

    {:reply, result, state}
  end

  def handle_call({:catch_up, options}, _from, state) do
    {:reply, catch_up_to(state.path, Court.max_event_seq(), options), state}
  end

  defp materialize_definition(path, definition, prior) do
    target = Court.max_event_seq()

    with {:ok, bytes} <- render_prefix(target),
         :ok <- Cursor.replace(path, bytes),
         {:ok, content_ref} <- Artifacts.publish(bytes),
         descriptor <- descriptor(definition, target, content_ref),
         identity <- Runtime.Lifecycle.identity(),
         {:ok, created} <- Registry.record_created(descriptor, identity),
         {:ok, superseded} <- maybe_supersede(prior, created, identity) do
      {:ok,
       %{
         target_event_seq: target,
         content_ref: content_ref,
         created: created,
         superseded: superseded
       }}
    end
  end

  defp rebuild_same_definition(path, active) do
    target = get_in(active.payload, ["cursor"])
    expected_ref = get_in(active.payload, ["content_ref"])

    with {:ok, %Court.Artifacts.Resolution{state: :available, integrity_fault: false}} <-
           Artifacts.resolve(expected_ref),
         {:ok, bytes} <- render_prefix(target),
         actual_ref <- content_ref(bytes),
         :ok <- require_same_content(expected_ref, actual_ref),
         :ok <- Cursor.replace(path, bytes) do
      {:ok, %{target_event_seq: target, content_ref: expected_ref, created: nil, superseded: nil}}
    else
      {:ok, resolution} ->
        {:error,
         %ProjectionError{
           code: :integrity_fault,
           message: "registered projection content is unavailable",
           details: %{resolution: resolution}
         }}

      error ->
        error
    end
  end

  defp catch_up_to(path, target, options) do
    with {:ok, cursor} <- Cursor.recover(path),
         :ok <- require_cursor_not_ahead(cursor, target),
         {:ok, events} <- events_after(cursor, target),
         :ok <-
           Cursor.append_lines(path, Enum.map(events, &render/1),
             checkpoint: Keyword.get(options, :checkpoint, fn _phase, _metadata -> :ok end),
             partial_at: Keyword.get(options, :partial_at)
           ) do
      {:ok, %{from_event_seq: cursor + 1, target_event_seq: target, appended: length(events)}}
    end
  end

  defp render_prefix(0), do: {:ok, <<>>}

  defp render_prefix(target) do
    with {:ok, events} <- Court.by_seq_range(1, target),
         :ok <- require_exact_prefix(events, target) do
      {:ok, events |> Enum.map(&render/1) |> IO.iodata_to_binary()}
    end
  end

  defp events_after(cursor, target) when cursor == target, do: {:ok, []}

  defp events_after(cursor, target) do
    with {:ok, events} <- Court.by_seq_range(cursor + 1, target),
         :ok <- require_exact_range(events, cursor + 1, target) do
      {:ok, events}
    end
  end

  defp require_exact_prefix(events, target), do: require_exact_range(events, 1, target)

  defp require_exact_range(events, first, last) do
    actual = Enum.map(events, & &1.event_seq)
    expected = Enum.to_list(first..last)

    if actual == expected do
      :ok
    else
      {:error,
       %ProjectionError{
         code: :integrity_fault,
         message: "court read did not return the exact requested prefix",
         details: %{expected: expected, actual: actual}
       }}
    end
  end

  defp require_cursor_not_ahead(cursor, target) when cursor <= target, do: :ok

  defp require_cursor_not_ahead(cursor, target) do
    {:error,
     %ProjectionError{
       code: :integrity_fault,
       message: "projection cursor is ahead of the court",
       details: %{cursor: cursor, target: target}
     }}
  end

  defp require_same_content(expected, expected), do: :ok

  defp require_same_content(expected, actual) do
    {:error,
     %ProjectionError{
       code: :determinism_failure,
       message: "same-definition projection rebuild changed bytes",
       details: %{expected: expected, actual: actual}
     }}
  end

  defp maybe_supersede(nil, _created, _identity), do: {:ok, nil}

  defp maybe_supersede(prior, created, identity),
    do: Registry.record_superseded(prior, created, identity)

  defp descriptor(definition, target, content_ref) do
    definition
    |> Map.merge(%{
      "projection_id" => Court.new_id(),
      "content_ref" => content_ref,
      "source_ranges" => source_ranges(target),
      "cursor" => target,
      "precision" => "exact",
      "trust" => "derived",
      "status" => "active"
    })
  end

  defp source_ranges(0), do: []

  defp source_ranges(target),
    do: [%{"from_event_seq" => 1, "to_event_seq" => target}]

  defp content_ref(bytes),
    do: "sha256:" <> (:crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower))

  defp configured_path do
    :runtime
    |> Application.fetch_env!(__MODULE__)
    |> Keyword.fetch!(:path)
  end
end
