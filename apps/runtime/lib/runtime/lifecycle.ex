defmodule Runtime.Lifecycle do
  @moduledoc """
  Records the resident root, per-BEAM incarnation, clean terminals, and
  crash inferences. A supervised child restart reuses the incarnation
  captured in its child specification; only a new BEAM boot mints one.
  """

  use GenServer

  alias Court.Writer
  alias Runtime.Lifecycle.Identity

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) do
    name = Keyword.get(options, :name, __MODULE__)
    genserver_options = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, options, genserver_options)
  end

  @spec identity(GenServer.server()) :: Identity.t()
  def identity(server \\ __MODULE__), do: GenServer.call(server, :identity)

  @spec scan_orphans(GenServer.server()) :: {:ok, [Court.Event.t()]}
  def scan_orphans(server \\ __MODULE__), do: GenServer.call(server, :scan_orphans, 30_000)

  @doc false
  @spec boot(String.t()) :: {:ok, Identity.t(), [Court.Event.t()]} | {:error, Court.Error.t()}
  def boot(incarnation_id) do
    candidate_resident_id = Court.new_id()

    with {:ok, resident_event} <-
           Writer.ensure_resident_created(
             lifecycle_event(
               "resident_created",
               candidate_resident_id,
               incarnation_id,
               "resident",
               %{}
             )
           ),
         identity = %Identity{
           resident_id: resident_event.resident_id,
           incarnation_id: incarnation_id
         },
         {:ok, _started} <-
           Writer.ensure_incarnation_started(
             lifecycle_event(
               "incarnation_started",
               identity.resident_id,
               identity.incarnation_id,
               "resident",
               %{}
             )
           ),
         {:ok, inferences} <- scan_identity_orphans(identity) do
      {:ok, identity, inferences}
    end
  end

  @doc false
  @spec end_incarnation(Identity.t()) :: {:ok, Court.Event.t()} | {:error, Court.Error.t()}
  def end_incarnation(%Identity{} = identity) do
    Writer.ensure_incarnation_ended(
      lifecycle_event(
        "incarnation_ended",
        identity.resident_id,
        identity.incarnation_id,
        "resident",
        %{}
      )
    )
  end

  @doc false
  @spec scan_identity_orphans(Identity.t()) :: {:ok, [Court.Event.t()]}
  def scan_identity_orphans(%Identity{} = identity) do
    with {:ok, started} <- Court.by_type("incarnation_started"),
         {:ok, ended} <- Court.by_type("incarnation_ended"),
         {:ok, inferred} <- Court.by_type("incarnation_crash_inferred") do
      ended_ids = MapSet.new(ended, & &1.incarnation_id)
      inferred_ids = MapSet.new(inferred, &get_in(&1.payload, ["orphan_incarnation_id"]))

      started
      |> Enum.filter(&(&1.resident_id == identity.resident_id))
      |> Enum.map(& &1.incarnation_id)
      |> Enum.uniq()
      |> Enum.reject(&(&1 == identity.incarnation_id))
      |> Enum.reject(&MapSet.member?(ended_ids, &1))
      |> Enum.reject(&MapSet.member?(inferred_ids, &1))
      |> Enum.reduce_while({:ok, []}, fn orphan_incarnation_id, {:ok, events} ->
        attrs =
          lifecycle_event(
            "incarnation_crash_inferred",
            identity.resident_id,
            identity.incarnation_id,
            "recovery",
            %{"orphan_incarnation_id" => orphan_incarnation_id}
          )

        case Writer.infer_incarnation_crash(orphan_incarnation_id, attrs) do
          {:ok, :not_orphan} -> {:cont, {:ok, events}}
          {:ok, event} -> {:cont, {:ok, [event | events]}}
          {:error, error} -> {:halt, {:error, error}}
        end
      end)
      |> case do
        {:ok, events} -> {:ok, Enum.reverse(events)}
        error -> error
      end
    end
  end

  @impl true
  def init(options) do
    incarnation_id = Keyword.fetch!(options, :incarnation_id)

    case boot(incarnation_id) do
      {:ok, identity, _inferences} -> {:ok, identity}
      {:error, error} -> {:stop, error}
    end
  end

  @impl true
  def handle_call(:identity, _from, identity), do: {:reply, identity, identity}

  def handle_call(:scan_orphans, _from, identity) do
    {:reply, scan_identity_orphans(identity), identity}
  end

  @impl true
  def terminate(:shutdown, %Identity{} = identity) do
    _ = end_incarnation(identity)
    :ok
  end

  def terminate({:shutdown, _reason}, %Identity{} = identity) do
    _ = end_incarnation(identity)
    :ok
  end

  def terminate(_reason, %Identity{}), do: :ok

  defp lifecycle_event(event_type, resident_id, incarnation_id, actor, payload) do
    %{
      event_id: Court.new_id(),
      event_type: event_type,
      schema_version: 1,
      occurred_at: DateTime.utc_now(),
      actor: actor,
      resident_id: resident_id,
      incarnation_id: incarnation_id,
      payload: payload,
      artifact_refs: []
    }
  end
end
