import Config

run_id = "#{System.system_time(:microsecond)}_#{System.unique_integer([:positive, :monotonic])}"

database =
  System.get_env("VAMPIRE_OTP_TEST_DB") ||
    Path.join(System.tmp_dir!(), "vampire_otp_test_#{run_id}.sqlite3")

artifact_root =
  System.get_env("VAMPIRE_OTP_ARTIFACT_ROOT") ||
    Path.join(System.tmp_dir!(), "vampire_otp_test_artifacts_#{run_id}")

config :court, Court.Repo,
  database: database,
  pool_size: 1,
  stacktrace: true

config :court, Court.Artifacts, root: artifact_root

config :logger, level: :warning
