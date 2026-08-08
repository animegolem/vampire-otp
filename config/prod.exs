import Config

config :court, Court.Repo,
  database:
    System.get_env("VAMPIRE_OTP_DB") ||
      Path.join(System.tmp_dir!(), "vampire_otp_prod.sqlite3")

config :court, Court.Artifacts,
  root:
    System.get_env("VAMPIRE_OTP_ARTIFACT_ROOT") ||
      Path.join(System.tmp_dir!(), "vampire_otp_prod_artifacts")
