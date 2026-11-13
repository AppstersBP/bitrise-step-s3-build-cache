load ../helpers/common

@test "step.sh sources all libraries without running main" {
  run bash -c 'S3_CACHE_NO_MAIN=1 source ./step.sh && declare -F log_info'
  [ "$status" -eq 0 ]
}

@test "aws stub logs its calls" {
  setup_env
  run aws s3api head-bucket --bucket b
  assert_called "aws s3api head-bucket --bucket b"
}
