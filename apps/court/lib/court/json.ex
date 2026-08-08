defmodule Court.JSON do
  @moduledoc false

  @spec encode_to_iodata!(term()) :: iodata()
  def encode_to_iodata!(value), do: :json.encode(value)

  @spec encode!(term()) :: binary()
  def encode!(value), do: value |> encode_to_iodata!() |> IO.iodata_to_binary()

  @spec decode(binary()) :: {:ok, term()} | {:error, Exception.t()}
  def decode(value) when is_binary(value) do
    {:ok, :json.decode(value)}
  rescue
    error -> {:error, error}
  end

  @spec decode!(binary()) :: term()
  def decode!(value) when is_binary(value), do: :json.decode(value)
end
