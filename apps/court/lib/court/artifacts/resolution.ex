defmodule Court.Artifacts.Resolution do
  @moduledoc "Stable artifact resolution derived from court events and durable bytes."

  @enforce_keys [:ref, :state]
  defstruct [:ref, :state, :request_event_id, :tombstone_event_id, integrity_fault: false]

  @type state :: :available | :tombstoned | :missing | :deletion_pending
  @type t :: %__MODULE__{
          ref: String.t(),
          state: state(),
          request_event_id: String.t() | nil,
          tombstone_event_id: String.t() | nil,
          integrity_fault: boolean()
        }
end
