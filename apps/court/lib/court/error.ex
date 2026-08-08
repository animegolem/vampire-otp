defmodule Court.Error do
  @moduledoc """
  Stable error returned by Court's public typed APIs.

  Changesets and adapter exceptions stay inside the court boundary.
  """

  @enforce_keys [:code, :message]
  defstruct [:code, :message, details: %{}]

  @type code ::
          :event_id_conflict
          | :artifact_io
          | :artifact_unavailable
          | :integrity_fault
          | :invalid_artifact_ref
          | :invalid_artifact_state
          | :invalid_event
          | :invalid_lifecycle_state
          | :invalid_prefix
          | :invalid_query
          | :not_found
          | :storage_error
          | :synthetic_disabled

  @type t :: %__MODULE__{code: code(), message: String.t(), details: map()}
end
