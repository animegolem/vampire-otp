defmodule Driver.ApplicationTest do
  use ExUnit.Case, async: false

  test "driver application and supervisor are running" do
    assert {:driver, _description, _version} =
             Enum.find(Application.started_applications(), fn {app, _, _} -> app == :driver end)

    assert Process.alive?(Process.whereis(Driver.Supervisor))
  end
end
