defmodule Court.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link([Court.Repo], strategy: :one_for_one, name: Court.Supervisor)
  end
end
