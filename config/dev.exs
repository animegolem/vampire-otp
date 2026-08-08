import Config

config :court, Court.Repo, database: Path.join(System.tmp_dir!(), "vampire_otp_dev.sqlite3")
