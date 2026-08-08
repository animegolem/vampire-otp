defmodule Scheduler.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link([Scheduler.Admission],
      strategy: :one_for_one,
      name: Scheduler.Supervisor
    )
  end
end
