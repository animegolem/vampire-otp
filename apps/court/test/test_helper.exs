ExUnit.start()

migrations_path = Application.app_dir(:court, "priv/repo/migrations")
Ecto.Migrator.run(Court.Repo, migrations_path, :up, all: true, log: false)
