import Config

config :court, ecto_repos: [Court.Repo]
config :ecto_sqlite3, json_library: Court.JSON

import_config "#{config_env()}.exs"
