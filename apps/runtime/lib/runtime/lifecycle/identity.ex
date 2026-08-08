defmodule Runtime.Lifecycle.Identity do
  @moduledoc "A resident root paired with the recording incarnation for one BEAM boot."

  @enforce_keys [:resident_id, :incarnation_id]
  defstruct [:resident_id, :incarnation_id]

  @type t :: %__MODULE__{resident_id: String.t(), incarnation_id: String.t()}
end
