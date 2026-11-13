load ../helpers/common

setup() { setup_env; }
teardown() { teardown_env; }

@test "aws stub dispatches with global options before the subcommand" {
  export STUB_AWS_HEAD_BUCKET_EXIT=3
  run aws --endpoint-url http://x:9000 --cli-connect-timeout 10 --region us-east-1 s3api head-bucket --bucket b
  [ "$status" -eq 3 ]
  assert_called "aws --endpoint-url http://x:9000 --cli-connect-timeout 10 --region us-east-1 s3api head-bucket --bucket b"
}

@test "aws stub head-bucket succeeds by default with global options" {
  run aws --no-verify-ssl --endpoint-url=http://x s3api head-bucket --bucket b
  [ "$status" -eq 0 ]
}

@test "aws stub list-objects-v2 returns its output after global options" {
  export STUB_AWS_LIST_OUT="some/key"
  run aws --cli-connect-timeout 5 s3api list-objects-v2 --bucket b --prefix p
  [ "$status" -eq 0 ]
  [ "$output" = "some/key" ]
}

@test "aws stub fails loudly on an unknown subcommand" {
  run aws --cli-connect-timeout 5 s3api delete-object --bucket b --key k
  [ "$status" -ne 0 ]
  [[ "$output" == *"unsupported"* ]]
}

@test "aws stub s3 cp download with extra value options copies the file" {
  echo data >"${TEST_TMP}/obj"
  export STUB_AWS_GET_FILE="${TEST_TMP}/obj"
  run aws --endpoint-url http://x s3 cp s3://b/k "${TEST_TMP}/dest" --expected-size 100 --storage-class STANDARD --only-show-errors
  [ "$status" -eq 0 ]
  [ "$(cat "${TEST_TMP}/dest")" = "data" ]
}

@test "aws stub s3 cp download without GET file reports not found" {
  run aws s3 cp --cache-control no-cache s3://b/k "${TEST_TMP}/dest"
  [ "$status" -eq 1 ]
}

@test "aws stub s3 cp upload with extra value options uses the put exit code" {
  export STUB_AWS_PUT_EXIT=7
  echo data >"${TEST_TMP}/up"
  run aws --cli-connect-timeout 10 s3 cp "${TEST_TMP}/up" s3://b/k --expected-size 5 --storage-class STANDARD --no-progress
  [ "$status" -eq 7 ]
}
