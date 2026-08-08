defmodule Runtime.BootIdentity do
  @moduledoc "Owns the one incarnation identifier minted for this BEAM boot."

  @key {__MODULE__, :incarnation_id}

  @spec current() :: String.t()
  def current do
    case :persistent_term.get(@key, nil) do
      nil ->
        incarnation_id = Court.new_id()
        :persistent_term.put(@key, incarnation_id)
        incarnation_id

      incarnation_id ->
        incarnation_id
    end
  end
end
