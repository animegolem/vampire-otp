defmodule Court.Artifacts.Ref do
  @moduledoc false

  alias Court.Error

  @sha256 ~r/^[0-9a-f]{64}$/

  @spec parse(String.t()) ::
          {:ok, %{algorithm: String.t(), digest: String.t()}} | {:error, Error.t()}
  def parse("sha256:" <> digest) do
    if Regex.match?(@sha256, digest) do
      {:ok, %{algorithm: "sha256", digest: digest}}
    else
      invalid_ref()
    end
  end

  def parse(_ref), do: invalid_ref()

  @spec path(String.t(), String.t()) :: {:ok, String.t()} | {:error, Error.t()}
  def path(ref, root) do
    with {:ok, %{algorithm: algorithm, digest: digest}} <- parse(ref) do
      <<shard::binary-size(2), rest::binary>> = digest
      {:ok, Path.join([root, algorithm, shard, rest])}
    end
  end

  defp invalid_ref do
    {:error,
     %Error{
       code: :invalid_artifact_ref,
       message: "artifact ref must be sha256 followed by 64 lowercase hexadecimal characters"
     }}
  end
end
