defmodule Scheduler.Error do
  @moduledoc "Typed failure returned by the M1 admission shell."

  @enforce_keys [:code, :message]
  defstruct [:code, :message, details: %{}]

  @type code :: :court_rejected | :invalid_context
  @type t :: %__MODULE__{code: code(), message: String.t(), details: map()}
end
