defmodule Scheduler.Admission do
  @moduledoc """
  M1's single admission authority and per-resident pause/stop cache.

  A successful admission returns an ephemeral probe reference only. It
  is not a durable permit, job, resource claim, lease, dispatch token,
  or any portion of M2's scheduler authority.
  """

  use GenServer

  alias Scheduler.Error

  @transition_types ~w(resident_paused resident_resumed resident_stopped)

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put_new(options, :name, __MODULE__))
  end

  @spec request_admission(map()) ::
          {:ok, reference()} | {:denied, :paused | :stopped} | {:error, Error.t()}
  def request_admission(context),
    do: GenServer.call(__MODULE__, {:request_admission, context}, 30_000)

  @spec pause(map()) :: {:ok, Court.Event.t() | :noop} | {:error, Error.t()}
  def pause(context), do: GenServer.call(__MODULE__, {:transition, :pause, context}, 30_000)

  @spec resume(map()) :: {:ok, Court.Event.t() | :noop} | {:error, Error.t()}
  def resume(context), do: GenServer.call(__MODULE__, {:transition, :resume, context}, 30_000)

  @spec stop(map()) :: {:ok, Court.Event.t() | :noop} | {:error, Error.t()}
  def stop(context), do: GenServer.call(__MODULE__, {:transition, :stop, context}, 30_000)

  @spec state(String.t()) :: :running | :paused | :stopped
  def state(resident_id), do: GenServer.call(__MODULE__, {:state, resident_id})

  @impl true
  def init(:ok), do: {:ok, rebuild_state()}

  @impl true
  def handle_call({:state, resident_id}, _from, states) do
    {:reply, status(states, resident_id), states}
  end

  def handle_call({:request_admission, context}, _from, states) do
    with :ok <- validate_context(context) do
      resident_id = Map.fetch!(context, :resident_id)

      case status(states, resident_id) do
        :running ->
          {:reply, {:ok, make_ref()}, states}

        denied_state ->
          case append_denial(context, denied_state, states) do
            {:ok, _event} -> {:reply, {:denied, denied_state}, states}
            {:error, error} -> {:reply, {:error, court_error(error)}, states}
          end
      end
    else
      {:error, %Error{} = error} -> {:reply, {:error, error}, states}
    end
  end

  def handle_call({:transition, transition, context}, _from, states) do
    with :ok <- validate_context(context) do
      resident_id = Map.fetch!(context, :resident_id)
      current = status(states, resident_id)

      case transition_action(current, transition) do
        :noop ->
          {:reply, {:ok, :noop}, states}

        {:append, event_type, next_state, payload} ->
          case Court.append(
                 event(context, event_type, Map.fetch!(context, :actor), payload, states)
               ) do
            {:ok, committed} ->
              next_states =
                Map.put(states, resident_id, %{status: next_state, event_id: committed.event_id})

              {:reply, {:ok, committed}, next_states}

            {:error, error} ->
              {:reply, {:error, court_error(error)}, states}
          end

        {:deny_transition, payload} ->
          case Court.append(
                 event(context, "lifecycle_transition_denied", "scheduler", payload, states)
               ) do
            {:ok, committed} -> {:reply, {:ok, committed}, states}
            {:error, error} -> {:reply, {:error, court_error(error)}, states}
          end
      end
    else
      {:error, %Error{} = error} -> {:reply, {:error, error}, states}
    end
  end

  defp transition_action(:running, :pause),
    do: {:append, "resident_paused", :paused, %{"resumable" => true}}

  defp transition_action(:paused, :resume),
    do: {:append, "resident_resumed", :running, %{}}

  defp transition_action(state, :stop) when state in [:running, :paused],
    do: {:append, "resident_stopped", :stopped, %{"terminal" => true}}

  defp transition_action(:running, :resume), do: :noop
  defp transition_action(:paused, :pause), do: :noop
  defp transition_action(:stopped, :stop), do: :noop

  defp transition_action(:stopped, transition) do
    {:deny_transition,
     %{
       "requested_transition" => Atom.to_string(transition),
       "reason" => "stopped_is_terminal"
     }}
  end

  defp append_denial(context, denied_state, states) do
    payload = %{
      "reason" => Atom.to_string(denied_state),
      "requested_by" => Map.fetch!(context, :actor)
    }

    Court.append(event(context, "admission_denied", "scheduler", payload, states))
  end

  defp event(context, event_type, actor, payload, states) do
    resident_id = Map.get(context, :resident_id)
    prior = Map.get(states, resident_id)

    %{
      event_id: Court.new_id(),
      event_type: event_type,
      schema_version: 1,
      occurred_at: Map.get(context, :occurred_at, DateTime.utc_now()),
      actor: actor,
      causation_id: prior && prior.event_id,
      correlation_id: Map.get(context, :correlation_id),
      resident_id: resident_id,
      incarnation_id: Map.get(context, :incarnation_id),
      payload: payload,
      artifact_refs: []
    }
  end

  defp validate_context(context) when is_map(context) do
    probe =
      event(
        Map.put_new(context, :actor, nil),
        "scheduler_context_probe",
        Map.get(context, :actor),
        %{},
        %{}
      )

    case Court.Event.normalize(probe) do
      {:ok, _event} ->
        :ok

      {:error, details} ->
        {:error,
         %Error{
           code: :invalid_context,
           message: "recording context is invalid",
           details: details
         }}
    end
  end

  defp validate_context(_context),
    do: {:error, %Error{code: :invalid_context, message: "recording context must be a map"}}

  defp rebuild_state do
    @transition_types
    |> Enum.flat_map(fn event_type ->
      {:ok, events} = Court.by_type(event_type)
      events
    end)
    |> Enum.sort_by(& &1.event_seq)
    |> Enum.reduce(%{}, fn event, states ->
      prior = Map.get(states, event.resident_id, %{status: :running, event_id: nil})

      next =
        case {prior.status, event.event_type} do
          {:stopped, _event_type} -> prior
          {_state, "resident_paused"} -> %{status: :paused, event_id: event.event_id}
          {_state, "resident_resumed"} -> %{status: :running, event_id: event.event_id}
          {_state, "resident_stopped"} -> %{status: :stopped, event_id: event.event_id}
        end

      Map.put(states, event.resident_id, next)
    end)
  end

  defp status(states, resident_id),
    do: states |> Map.get(resident_id, %{status: :running}) |> Map.fetch!(:status)

  defp court_error(error),
    do: %Error{
      code: :court_rejected,
      message: "court rejected scheduler transition",
      details: %{court: error}
    }
end
