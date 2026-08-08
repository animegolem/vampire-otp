import Config

database =
  System.get_env("VAMPIRE_OTP_TEST_DB") ||
    Path.join(
      System.tmp_dir!(),
      "vampire_otp_test_#{System.system_time(:microsecond)}_#{System.unique_integer([:positive, :monotonic])}.sqlite3"
    )

config :court, Court.Repo,
  database: database,
  pool_size: 1,
  stacktrace: true

config :logger, level: :warning
