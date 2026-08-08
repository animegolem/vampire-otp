defmodule Broker.ApplicationTest do
  use ExUnit.Case, async: false

  test "broker application and supervisor are running" do
    assert {:broker, _description, _version} =
             Enum.find(Application.started_applications(), fn {app, _, _} -> app == :broker end)

    assert Process.alive?(Process.whereis(Broker.Supervisor))
  end
end
