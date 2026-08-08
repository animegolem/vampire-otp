defmodule Court.Error do
  @moduledoc """
  Stable error returned by Court's public typed APIs.

  Changesets and adapter exceptions stay inside the court boundary.
  """

  @enforce_keys [:code, :message]
  defstruct [:code, :message, details: %{}]

  @type code ::
          :event_id_conflict
          | :invalid_event
          | :invalid_query
          | :not_found
          | :storage_error

  @type t :: %__MODULE__{code: code(), message: String.t(), details: map()}
end
