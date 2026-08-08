defmodule Runtime.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [{Runtime.Lifecycle, incarnation_id: Runtime.BootIdentity.current()}]
    Supervisor.start_link(children, strategy: :one_for_one, name: Runtime.Supervisor)
  end
end
