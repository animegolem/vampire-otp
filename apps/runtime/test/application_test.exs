defmodule Runtime.ApplicationTest do
  use ExUnit.Case, async: false

  test "runtime application and supervisor are running" do
    assert {:runtime, _description, _version} =
             Enum.find(Application.started_applications(), fn {app, _, _} -> app == :runtime end)

    assert Process.alive?(Process.whereis(Runtime.Supervisor))
    assert Process.alive?(Process.whereis(Runtime.Lifecycle))
    assert Process.alive?(Process.whereis(Runtime.Projections.Logs))
    assert %Runtime.Lifecycle.Identity{} = Runtime.Lifecycle.identity()
  end
end
