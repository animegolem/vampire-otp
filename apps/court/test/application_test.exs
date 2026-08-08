defmodule Court.ApplicationTest do
  use ExUnit.Case, async: false

  test "court application and supervisor are running" do
    assert {:court, _description, _version} =
             Enum.find(Application.started_applications(), fn {app, _, _} -> app == :court end)

    assert Process.alive?(Process.whereis(Court.Supervisor))
    assert Process.alive?(Process.whereis(Court.Repo))
    assert Process.alive?(Process.whereis(Court.Writer))
  end
end
