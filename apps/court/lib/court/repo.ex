defmodule Court.Repo do
  use Ecto.Repo,
    otp_app: :court,
    adapter: Ecto.Adapters.SQLite3
end
