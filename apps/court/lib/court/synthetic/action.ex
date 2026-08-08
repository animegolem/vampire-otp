defmodule Court.Synthetic.Action do
  @moduledoc """
  Disposable, deliberately non-conformant M1 action aggregate.

  This module exists only to exercise the court and recovery oracle
  before the broker exists. It grants no authority, implements none of
  A.3's transactional dispatch guard, and MUST be deleted when M2's
  real broker action aggregate lands.
  """

  @enforce_keys [:action_id, :correlation_id, :context, :idempotency]
  defstruct [
    :action_id,
    :correlation_id,
    :context,
    :idempotency,
    :attempt_id,
    :last_event_id
  ]

  @type t :: %__MODULE__{
          action_id: String.t(),
          correlation_id: String.t(),
          context: map(),
          idempotency: :idempotent | :non_idempotent,
          attempt_id: String.t() | nil,
          last_event_id: String.t() | nil
        }

  @spec propose(map(), keyword()) :: {:ok, t(), Court.Event.t()} | {:error, Court.Error.t()}
  def propose(context, options \\ []) do
    action = %__MODULE__{
      action_id: Court.new_id(),
      correlation_id: Court.new_id(),
      context: context,
      idempotency: Keyword.get(options, :idempotency, :non_idempotent)
    }

    payload = %{
      "action_id" => action.action_id,
      "operation" => Keyword.get(options, :operation, "synthetic_probe"),
      "idempotency" => Atom.to_string(action.idempotency)
    }

    append(action, "synthetic_action_proposed", payload,
      artifact_refs: Keyword.get(options, :artifact_refs, [])
    )
  end

  @spec approve(t()) :: {:ok, t(), Court.Event.t()} | {:error, Court.Error.t()}
  def approve(%__MODULE__{} = action) do
    append(action, "synthetic_action_approved", %{"action_id" => action.action_id})
  end

  @spec claim(t()) :: {:ok, t(), Court.Event.t()} | {:error, Court.Error.t()}
  def claim(%__MODULE__{} = action) do
    attempt_id = Court.new_id()

    append(
      %{action | attempt_id: attempt_id},
      "synthetic_attempt_claimed",
      action_payload(action, attempt_id)
    )
  end

  @spec dispatch(t()) :: {:ok, t(), Court.Event.t()} | {:error, Court.Error.t()}
  def dispatch(%__MODULE__{attempt_id: attempt_id} = action) when is_binary(attempt_id) do
    append(action, "synthetic_attempt_dispatched", action_payload(action, attempt_id))
  end

  @spec succeed(t()) :: {:ok, t(), Court.Event.t()} | {:error, Court.Error.t()}
  def succeed(%__MODULE__{attempt_id: attempt_id} = action) when is_binary(attempt_id) do
    append(action, "synthetic_attempt_succeeded", action_payload(action, attempt_id))
  end

  @spec fail(t()) :: {:ok, t(), Court.Event.t()} | {:error, Court.Error.t()}
  def fail(%__MODULE__{attempt_id: attempt_id} = action) when is_binary(attempt_id) do
    append(action, "synthetic_attempt_failed", action_payload(action, attempt_id))
  end

  @spec dispatched_unknown(map(), keyword()) ::
          {:ok, t(), [Court.Event.t()]} | {:error, Court.Error.t()}
  def dispatched_unknown(context, options \\ []) do
    with {:ok, action, proposed} <- propose(context, options),
         {:ok, action, approved} <- approve(action),
         {:ok, action, claimed} <- claim(action),
         {:ok, action, dispatched} <- dispatch(action) do
      {:ok, action, [proposed, approved, claimed, dispatched]}
    end
  end

  defp action_payload(action, attempt_id) do
    %{
      "action_id" => action.action_id,
      "attempt_id" => attempt_id,
      "idempotency" => Atom.to_string(action.idempotency)
    }
  end

  defp append(action, event_type, payload, options \\ []) do
    payload = Map.put(payload, "fixture_contract", "m1_non_conformant_disposable")

    attrs = %{
      event_id: Court.new_id(),
      event_type: event_type,
      schema_version: 1,
      occurred_at: Map.get(action.context, :occurred_at, DateTime.utc_now()),
      actor: "worker/synthetic",
      causation_id: action.last_event_id,
      correlation_id: action.correlation_id,
      resident_id: Map.get(action.context, :resident_id),
      incarnation_id: Map.get(action.context, :incarnation_id),
      payload: payload,
      artifact_refs: Keyword.get(options, :artifact_refs, [])
    }

    if Application.get_env(:court, :synthetic_actions_enabled, false) do
      case Court.append(attrs) do
        {:ok, event} -> {:ok, %{action | last_event_id: event.event_id}, event}
        {:error, error} -> {:error, error}
      end
    else
      {:error,
       %Court.Error{
         code: :synthetic_disabled,
         message: "M1 synthetic actions are disabled outside the crash harness"
       }}
    end
  end
end
