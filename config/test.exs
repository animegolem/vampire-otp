import Config

run_id = "#{System.system_time(:microsecond)}_#{System.unique_integer([:positive, :monotonic])}"

database =
  System.get_env("VAMPIRE_OTP_TEST_DB") ||
    Path.join(System.tmp_dir!(), "vampire_otp_test_#{run_id}.sqlite3")

artifact_root =
  System.get_env("VAMPIRE_OTP_ARTIFACT_ROOT") ||
    Path.join(System.tmp_dir!(), "vampire_otp_test_artifacts_#{run_id}")

logs_path =
  System.get_env("VAMPIRE_OTP_LOGS_PATH") ||
    Path.join(System.tmp_dir!(), "vampire_otp_test_logs_#{run_id}.txt")

config :court, Court.Repo,
  database: database,
  pool_size: 1,
  stacktrace: true

config :court, Court.Artifacts, root: artifact_root
config :court, :failpoints_enabled, true
config :court, :synthetic_actions_enabled, true
config :runtime, Runtime.Projections.Logs, path: logs_path

config :logger, level: :warning
