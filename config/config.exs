import Config

config :court, ecto_repos: [Court.Repo]

import_config "#{config_env()}.exs"
