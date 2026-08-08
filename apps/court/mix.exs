defmodule Court.MixProject do
  use Mix.Project

  def project do
    [
      app: :court,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Court.Application, []}
    ]
  end

  defp deps do
    [
      {:ecto_sql, "~> 3.14"},
      {:ecto_sqlite3, "~> 0.24"},
      {:humble_ulid, "~> 0.1.0"}
    ]
  end
end
