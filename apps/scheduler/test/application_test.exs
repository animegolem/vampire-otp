defmodule Scheduler.ApplicationTest do
  use ExUnit.Case, async: false

  test "scheduler application and supervisor are running" do
    assert {:scheduler, _description, _version} =
             Enum.find(Application.started_applications(), fn {app, _, _} -> app == :scheduler end)

    assert Process.alive?(Process.whereis(Scheduler.Supervisor))
    assert Process.alive?(Process.whereis(Scheduler.Admission))
  end
end
