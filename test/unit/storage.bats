load ../helpers/common

setup() {
  setup_env
  S3_CACHE_NO_MAIN=1 source ./step.sh
  export mode=restore caches=gradle-deps bucket=b prefix=cache/x region=eu-central-1
  export endpoint=https://m:9005 access_key_id=AKIDEXAMPLE secret_access_key=SECRETVALUE123
  unset AWS_CONFIG_FILE AWS_SHARED_CREDENTIALS_FILE
}
teardown() { teardown_env; }

init_storage() {
  cfg_init
  storage_init
}

@test "every aws call carries endpoint, connect timeout and quiet output" {
  init_storage
  printf 'x' >"${TEST_TMP}/f"
  storage_get cache/x/k "${TEST_TMP}/out" || true
  storage_put "${TEST_TMP}/f" cache/x/k
  storage_touch cache/x/k
  storage_latest gradle-
  assert_called "--endpoint-url https://m:9005"
  assert_called "--cli-connect-timeout 10"
  assert_called "s3 cp --only-show-errors s3://b/cache/x/k ${TEST_TMP}/out"
  assert_called "s3 cp --only-show-errors ${TEST_TMP}/f s3://b/cache/x/k"
  [ "$(grep -c -- '--endpoint-url https://m:9005' "${STUB_LOG}")" -eq 4 ]
  [ "$(grep -c -- '--cli-connect-timeout 10' "${STUB_LOG}")" -eq 4 ]
}

@test "storage_init writes multipart and path-style settings to a private config file" {
  init_storage
  [ -f "${AWS_CONFIG_FILE}" ]
  grep -q "region = eu-central-1" "${AWS_CONFIG_FILE}"
  grep -q "multipart_threshold = 64MB" "${AWS_CONFIG_FILE}"
  grep -q "multipart_chunksize = 64MB" "${AWS_CONFIG_FILE}"
  grep -q "addressing_style = path" "${AWS_CONFIG_FILE}"
  [ ! -e "${HOME}/.aws/config" ]
  [ ! -e "${HOME}/.aws" ]
  case "${AWS_CONFIG_FILE}" in "${HOME}"/.aws/*) false ;; esac
  case "${AWS_SHARED_CREDENTIALS_FILE}" in "${HOME}"/.aws/*) false ;; esac
  ! grep -qF "SECRETVALUE123" "${AWS_CONFIG_FILE}"
  [ "${AWS_ACCESS_KEY_ID}" = "AKIDEXAMPLE" ]
  [ "${AWS_SECRET_ACCESS_KEY}" = "SECRETVALUE123" ]
  [ "${AWS_RETRY_MODE}" = "standard" ]
  [ "${AWS_MAX_ATTEMPTS}" = "2" ]
  [ "${AWS_REQUEST_CHECKSUM_CALCULATION}" = "when_required" ]
  [ "${AWS_RESPONSE_CHECKSUM_VALIDATION}" = "when_required" ]
}

@test "endpoint with trailing slash and http scheme" {
  export endpoint=http://m:9000//
  init_storage
  storage_touch cache/x/k
  assert_called "--endpoint-url http://m:9000 "
  refute_called "http://m:9000/"
}

@test "no endpoint means AWS S3: no --endpoint-url, no path style" {
  export endpoint=""
  init_storage
  storage_touch cache/x/k
  refute_called "--endpoint-url"
  ! grep -q "addressing_style" "${AWS_CONFIG_FILE}"
  grep -q "multipart_chunksize = 64MB" "${AWS_CONFIG_FILE}"
}

@test "reachability uses head-bucket with a short limit and a single attempt" {
  init_storage
  storage_reachable
  assert_called "s3api head-bucket --bucket b"
  assert_called "--cli-connect-timeout 5"
  assert_called "--cli-read-timeout 5"
  refute_called "--cli-connect-timeout 10"
}

@test "reachability reports failure" {
  init_storage
  STUB_AWS_HEAD_BUCKET_EXIT=255 run storage_reachable
  [ "$status" -ne 0 ]
}

@test "reachability makes a single attempt" {
  init_storage
  mkdir -p "${TEST_TMP}/bin"
  printf '#!/usr/bin/env bash\necho "attempts=${AWS_MAX_ATTEMPTS}" >>"${STUB_LOG}"\n' >"${TEST_TMP}/bin/aws"
  chmod +x "${TEST_TMP}/bin/aws"
  PATH="${TEST_TMP}/bin:${PATH}" storage_reachable
  assert_called "attempts=1"
  [ "${AWS_MAX_ATTEMPTS}" = "2" ]
}

@test "storage_object joins prefix and name" {
  init_storage
  [ "$(storage_object gradle-a.tar.zst)" = "cache/x/gradle-a.tar.zst" ]
}

@test "storage_get fails when the object is missing and succeeds when present" {
  init_storage
  run storage_get cache/x/k "${TEST_TMP}/out"
  [ "$status" -ne 0 ]
  printf 'data' >"${TEST_TMP}/payload"
  STUB_AWS_GET_FILE="${TEST_TMP}/payload" run storage_get cache/x/k "${TEST_TMP}/out"
  [ "$status" -eq 0 ]
  [ "$(cat "${TEST_TMP}/out")" = "data" ]
}

@test "storage_latest returns the newest key under the name prefix" {
  init_storage
  STUB_AWS_LIST_OUT=$'2026-11-13T10:00:00+00:00\tcache/x/gradle-b.tar.zst' run storage_latest gradle-
  [ "$status" -eq 0 ]
  [ "$output" = "cache/x/gradle-b.tar.zst" ]
  assert_called "s3api list-objects-v2 --bucket b --prefix cache/x/gradle-"
  assert_called 'Contents[].[LastModified,Key]'
  assert_called "--output text"
}

@test "storage_latest picks the newest key across several result pages" {
  init_storage
  STUB_AWS_LIST_OUT=$'2026-11-10T08:00:00+00:00\tcache/x/gradle-old\nNone\n2026-11-13T09:30:00+00:00\tcache/x/gradle-new\n2026-11-12T23:59:59+00:00\tcache/x/gradle-mid' run storage_latest gradle-
  [ "$status" -eq 0 ]
  [ "$output" = "cache/x/gradle-new" ]
}

@test "storage_latest returns empty for None and 1 when listing fails" {
  init_storage
  STUB_AWS_LIST_OUT="None" run storage_latest gradle-
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  STUB_AWS_LIST_OUT="" run storage_latest gradle-
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  STUB_AWS_LIST_EXIT=255 run storage_latest gradle-
  [ "$status" -eq 1 ]
}

@test "storage_touch copies the object onto itself replacing metadata" {
  init_storage
  storage_touch cache/x/k
  assert_called "s3api copy-object --bucket b --key cache/x/k --copy-source b/cache/x/k --metadata-directive REPLACE"
}

@test "storage_touch passes the copy source unencoded (the AWS CLI encodes it)" {
  init_storage
  storage_touch "cache/x/a b+c"
  assert_called "--key cache/x/a b+c --copy-source b/cache/x/a b+c --metadata-directive"
}

@test "storage_touch reports failure" {
  init_storage
  STUB_AWS_COPY_EXIT=1 run storage_touch cache/x/k
  [ "$status" -ne 0 ]
}

@test "secret key never appears in stub logs or output" {
  init_storage
  printf 'x' >"${TEST_TMP}/f"
  {
    storage_reachable
    storage_put "${TEST_TMP}/f" cache/x/k
    storage_touch cache/x/k
    storage_latest gradle-
    storage_get cache/x/k "${TEST_TMP}/out"
  } >"${TEST_TMP}/all.out" 2>&1 || true
  ! grep -qF "SECRETVALUE123" "${STUB_LOG}"
  ! grep -qF "SECRETVALUE123" "${TEST_TMP}/all.out"
}

@test "credentials in the endpoint are not logged" {
  export endpoint=https://user:pw123@m:9005/
  run init_storage
  [ "$status" -eq 0 ]
  [[ "$output" != *"pw123"* ]]
  [[ "$output" == *"https://m:9005"* ]]
}
