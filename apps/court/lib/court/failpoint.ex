defmodule Court.Failpoint do
  @moduledoc false

  @key {__MODULE__, :armed}

  @doc false
  @spec arm(atom(), map(), pid()) :: reference()
  def arm(phase, target \\ %{}, observer \\ self())
      when is_atom(phase) and is_map(target) and is_pid(observer) do
    nonce = make_ref()
    :persistent_term.put(@key, {phase, target, observer, nonce})
    nonce
  end

  @doc false
  @spec disarm() :: :ok
  def disarm do
    :persistent_term.erase(@key)
    :ok
  end

  @doc false
  @spec hit(atom(), map()) :: :ok
  def hit(phase, metadata \\ %{}) when is_atom(phase) and is_map(metadata) do
    if Application.get_env(:court, :failpoints_enabled, false) do
      case :persistent_term.get(@key, nil) do
        {^phase, target, observer, nonce} ->
          if matches?(target, metadata) do
            :persistent_term.erase(@key)
            send(observer, {:court_failpoint, nonce, phase, metadata, self()})

            receive do
              {:court_failpoint_continue, ^nonce} -> :ok
            end
          else
            :ok
          end

        _other ->
          :ok
      end
    else
      :ok
    end
  end

  defp matches?(target, metadata) do
    Enum.all?(target, fn {key, expected} -> Map.get(metadata, key) == expected end)
  end
end
