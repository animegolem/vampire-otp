defmodule Runtime.Projections.Cursor do
  @moduledoc """
  Treats the final complete `logs.txt` line as the authoritative cursor.

  An incomplete suffix is truncated durably. A complete malformed line,
  gap, or regression is an integrity fault and is never silently rebuilt.
  """

  alias Runtime.ProjectionError

  @spec recover(String.t()) :: {:ok, non_neg_integer()} | {:error, ProjectionError.t()}
  def recover(path) do
    case File.read(path) do
      {:ok, bytes} -> recover_bytes(path, bytes)
      {:error, :enoent} -> {:ok, 0}
      {:error, reason} -> io_error("projection cursor read failed", reason)
    end
  end

  @spec append_lines(String.t(), [iodata()], keyword()) ::
          :ok | {:error, ProjectionError.t()}
  def append_lines(path, lines, options \\ []) do
    checkpoint = Keyword.get(options, :checkpoint, fn _phase, _metadata -> :ok end)
    partial_at = Keyword.get(options, :partial_at)

    with :ok <- ensure_parent(path),
         {:ok, file} <- :file.open(String.to_charlist(path), [:append, :binary, :raw]),
         :ok <- write_lines(file, lines, partial_at, checkpoint),
         :ok <- :file.sync(file),
         _ <- checkpoint.(:complete_lines_synced, %{path: path}),
         :ok <- :file.close(file),
         :ok <- sync_directory(Path.dirname(path)) do
      :ok
    else
      {:error, %ProjectionError{} = error} -> {:error, error}
      {:error, reason} -> io_error("projection append failed", reason)
    end
  rescue
    error -> io_error("projection append failed", error)
  catch
    kind, reason -> :erlang.raise(kind, reason, __STACKTRACE__)
  end

  @spec replace(String.t(), iodata()) :: :ok | {:error, ProjectionError.t()}
  def replace(path, contents) do
    bytes = IO.iodata_to_binary(contents)
    staging = path <> ".#{System.unique_integer([:positive, :monotonic])}.tmp"

    with :ok <- ensure_parent(path),
         {:ok, file} <-
           :file.open(String.to_charlist(staging), [:write, :binary, :raw, :exclusive]),
         :ok <- :file.write(file, bytes),
         :ok <- :file.sync(file),
         :ok <- :file.close(file),
         :ok <- :file.rename(String.to_charlist(staging), String.to_charlist(path)),
         :ok <- sync_directory(Path.dirname(path)) do
      :ok
    else
      {:error, reason} -> io_error("projection replacement failed", reason)
    end
  end

  defp recover_bytes(_path, <<>>), do: {:ok, 0}

  defp recover_bytes(path, bytes) do
    {complete, torn?} = complete_prefix(bytes)

    with :ok <- maybe_truncate(path, complete, torn?),
         {:ok, sequence} <- validate_complete_lines(complete) do
      {:ok, sequence}
    end
  end

  defp complete_prefix(bytes) do
    if String.ends_with?(bytes, "\n") do
      {bytes, false}
    else
      case :binary.matches(bytes, "\n") |> List.last() do
        {position, 1} -> {binary_part(bytes, 0, position + 1), true}
        nil -> {<<>>, true}
      end
    end
  end

  defp maybe_truncate(_path, _complete, false), do: :ok

  defp maybe_truncate(path, complete, true) do
    with {:ok, file} <- :file.open(String.to_charlist(path), [:read, :write, :binary, :raw]),
         {:ok, _position} <- :file.position(file, byte_size(complete)),
         :ok <- :file.truncate(file),
         :ok <- :file.sync(file),
         :ok <- :file.close(file) do
      :ok
    end
  end

  defp validate_complete_lines(<<>>), do: {:ok, 0}

  defp validate_complete_lines(bytes) do
    bytes
    |> String.split("\n", trim: true)
    |> Enum.reduce_while({:ok, 0}, fn line, {:ok, prior} ->
      case parse_sequence(line) do
        {:ok, sequence} when sequence == prior + 1 ->
          {:cont, {:ok, sequence}}

        {:ok, sequence} ->
          {:halt,
           integrity_error("projection cursor contains a gap or regression", %{
             prior: prior,
             sequence: sequence
           })}

        :error ->
          {:halt,
           integrity_error("projection cursor contains a malformed complete line", %{line: line})}
      end
    end)
  end

  defp parse_sequence(line) do
    case :binary.split(line, "\t") do
      [sequence, _rest] -> Integer.parse(sequence) |> parse_integer()
      _ -> :error
    end
  end

  defp parse_integer({integer, ""}) when integer > 0, do: {:ok, integer}
  defp parse_integer(_value), do: :error

  defp write_lines(file, lines, partial_at, checkpoint) do
    Enum.reduce_while(Enum.with_index(lines, 1), :ok, fn {line, index}, :ok ->
      bytes = IO.iodata_to_binary(line)

      if partial_at == index do
        partial_size = max(div(byte_size(bytes), 2), 1)
        partial = binary_part(bytes, 0, partial_size)

        with :ok <- :file.write(file, partial),
             :ok <- :file.sync(file),
             _ <- checkpoint.(:partial_line_synced, %{index: index}) do
          {:halt,
           integrity_error("partial-line checkpoint returned without a crash", %{index: index})}
        end
      else
        case :file.write(file, bytes) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end
    end)
  end

  defp ensure_parent(path) do
    case File.mkdir_p(Path.dirname(path)) do
      :ok -> :ok
      {:error, reason} -> io_error("projection directory creation failed", reason)
    end
  end

  defp sync_directory(path) do
    with {:ok, directory} <- :file.open(String.to_charlist(path), [:read, :raw, :directory]),
         :ok <- :file.sync(directory),
         :ok <- :file.close(directory) do
      :ok
    end
  end

  defp integrity_error(message, details),
    do: {:error, %ProjectionError{code: :integrity_fault, message: message, details: details}}

  defp io_error(message, reason),
    do:
      {:error,
       %ProjectionError{code: :io_error, message: message, details: %{reason: inspect(reason)}}}
end
