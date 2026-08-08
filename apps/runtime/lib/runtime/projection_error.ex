defmodule Runtime.ProjectionError do
  @moduledoc "Typed failure returned by projection APIs."

  @enforce_keys [:code, :message]
  defstruct [:code, :message, details: %{}]

  @type code :: :determinism_failure | :integrity_fault | :io_error | :not_built
  @type t :: %__MODULE__{code: code(), message: String.t(), details: map()}
end
