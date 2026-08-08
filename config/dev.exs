import Config

config :court, Court.Repo, database: Path.join(System.tmp_dir!(), "vampire_otp_dev.sqlite3")

config :court, Court.Artifacts, root: Path.join(System.tmp_dir!(), "vampire_otp_dev_artifacts")

config :runtime, Runtime.Projections.Logs,
  path: Path.join(System.tmp_dir!(), "vampire_otp_dev_logs.txt")
