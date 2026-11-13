load ../helpers/common

setup() {
  setup_env
  S3_CACHE_NO_MAIN=1 source ./step.sh
  export mode=restore caches=cocoapods bucket=b prefix=cache/x region=eu-central-1
  export endpoint=https://m:9005 access_key_id=AKIDEXAMPLE secret_access_key=SECRETVALUE123
  unset AWS_CONFIG_FILE AWS_SHARED_CREDENTIALS_FILE
  mkdir -p "${BITRISE_SOURCE_DIR}/ios"
  # Bytes that line filtering or text processing would change.
  printf 'PODS:\n  - A (1.0)\r\n\n# trailing\n\nCOCOAPODS: 1.15.2' >"${BITRISE_SOURCE_DIR}/ios/Podfile.lock"
  cfg_init
  storage_init 2>/dev/null
  HASH="$(shasum -a 256 "${BITRISE_SOURCE_DIR}/ios/Podfile.lock" | cut -d' ' -f1)"
  OBJECT="cache/x/pods-${HASH}.tar.zst"
  # A real archive of ios/Pods, served by the aws stub.
  SEED="${TEST_TMP}/seed"
  mkdir -p "${SEED}/ios/Pods/A"
  echo pod >"${SEED}/ios/Pods/A/a.h"
  archive_create "${TEST_TMP}/served.tar.zst" "${SEED}" ios/Pods 2>/dev/null
  : >"${STUB_LOG}"
}
teardown() { teardown_env; }

make_pods() {
  mkdir -p "${BITRISE_SOURCE_DIR}/ios/Pods/B"
  echo b >"${BITRISE_SOURCE_DIR}/ios/Pods/B/b.h"
}

@test "restore uses only the exact Podfile.lock key" {
  export STUB_AWS_GET_FILE="${TEST_TMP}/served.tar.zst"
  run cache_cocoapods_restore
  [ "$status" -eq 0 ]
  cache_cocoapods_restore 2>"${TEST_TMP}/err"
  [ "${S3_CACHE_RESULT_COCOAPODS}" = exact ]
  [ "$(state_get COCOAPODS_EXACT_KEY)" = "${OBJECT}" ]
  [ -f "${BITRISE_SOURCE_DIR}/ios/Pods/A/a.h" ]
  assert_called "s3://b/${OBJECT}"
  refute_called list-objects
  grep -qF "${OBJECT}" "${TEST_TMP}/err"
}

@test "restore miss reports none without a fallback" {
  cache_cocoapods_restore 2>/dev/null
  [ "${S3_CACHE_RESULT_COCOAPODS}" = none ]
  [ -z "$(state_get COCOAPODS_EXACT_KEY)" ]
  refute_called list-objects
  [ ! -e "${BITRISE_SOURCE_DIR}/ios/Pods" ]
}

@test "restore of a damaged archive reports none" {
  echo "not an archive" >"${TEST_TMP}/bad"
  export STUB_AWS_GET_FILE="${TEST_TMP}/bad"
  cache_cocoapods_restore 2>"${TEST_TMP}/err"
  [ "${S3_CACHE_RESULT_COCOAPODS}" = none ]
  [ -z "$(state_get COCOAPODS_EXACT_KEY)" ]
  refute_called list-objects
  grep -qi "damaged" "${TEST_TMP}/err"
}

@test "missing Podfile.lock skips with a warning" {
  rm "${BITRISE_SOURCE_DIR}/ios/Podfile.lock"
  run cache_cocoapods_restore
  [ "$status" -eq 0 ]
  cache_cocoapods_restore 2>"${TEST_TMP}/err"
  [ "${S3_CACHE_RESULT_COCOAPODS}" = skipped ]
  grep -qF "Podfile.lock" "${TEST_TMP}/err"
  refute_called "aws"
}

@test "the key is the SHA-256 of the lock file bytes" {
  cache_cocoapods_restore 2>/dev/null
  assert_called "s3://b/cache/x/pods-${HASH}.tar.zst"
  [ "${HASH}" = "$(cut -d' ' -f1 < <(shasum -a 256 "${BITRISE_SOURCE_DIR}/ios/Podfile.lock"))" ]
}

@test "an absolute lock file path is used as given" {
  cp "${BITRISE_SOURCE_DIR}/ios/Podfile.lock" "${TEST_TMP}/Other.lock"
  export cocoapods_lockfile="${TEST_TMP}/Other.lock"
  cfg_init
  cache_cocoapods_restore 2>/dev/null
  assert_called "s3://b/${OBJECT}"
}

@test "save after exact hit renews the date" {
  export STUB_AWS_GET_FILE="${TEST_TMP}/served.tar.zst"
  cache_cocoapods_restore 2>/dev/null
  : >"${STUB_LOG}"
  run cache_cocoapods_save
  [ "$status" -eq 0 ]
  cache_cocoapods_save 2>/dev/null
  [ "${S3_CACHE_SAVE_COCOAPODS}" = refreshed ]
  assert_called "copy-object"
  refute_called "s3 cp"
}

@test "failing renewal reports failed" {
  export STUB_AWS_GET_FILE="${TEST_TMP}/served.tar.zst"
  cache_cocoapods_restore 2>/dev/null
  export STUB_AWS_COPY_EXIT=1
  cache_cocoapods_save 2>/dev/null
  [ "${S3_CACHE_SAVE_COCOAPODS}" = failed ]
}

@test "cocoapods save without restore state uploads" {
  make_pods
  storage_put() {
    echo "put $2" >>"${STUB_LOG}"
    cp "$1" "${TEST_TMP}/uploaded.tar.zst"
  }
  cache_cocoapods_save 2>"${TEST_TMP}/err"
  [ "${S3_CACHE_SAVE_COCOAPODS}" = uploaded ]
  assert_called "put ${OBJECT}"
  tar --zstd -tf "${TEST_TMP}/uploaded.tar.zst" | grep -q "^ios/Pods/B/b.h"
  grep -qF "${OBJECT}" "${TEST_TMP}/err"
}

@test "save with a different restored key uploads" {
  make_pods
  state_set COCOAPODS_EXACT_KEY "cache/x/pods-other.tar.zst" 2>/dev/null
  cache_cocoapods_save 2>/dev/null
  [ "${S3_CACHE_SAVE_COCOAPODS}" = uploaded ]
  assert_called "s3://b/${OBJECT}"
}

@test "save reports failed when the upload fails" {
  make_pods
  export STUB_AWS_PUT_EXIT=1
  run cache_cocoapods_save
  [ "$status" -eq 0 ]
  cache_cocoapods_save 2>/dev/null
  [ "${S3_CACHE_SAVE_COCOAPODS}" = failed ]
}

@test "save with missing directory skips" {
  cache_cocoapods_save 2>"${TEST_TMP}/err"
  [ "${S3_CACHE_SAVE_COCOAPODS}" = skipped ]
  grep -qi "nothing to save" "${TEST_TMP}/err"
  refute_called "aws"
}

@test "save with missing lock file skips" {
  make_pods
  rm "${BITRISE_SOURCE_DIR}/ios/Podfile.lock"
  cache_cocoapods_save 2>/dev/null
  [ "${S3_CACHE_SAVE_COCOAPODS}" = skipped ]
  refute_called "aws"
}

@test "an absolute directory outside the source dir uses its parent as base" {
  mkdir -p "${TEST_TMP}/elsewhere/Pods/C"
  echo c >"${TEST_TMP}/elsewhere/Pods/C/c.h"
  export cocoapods_dir="${TEST_TMP}/elsewhere/Pods"
  cfg_init
  storage_put() { cp "$1" "${TEST_TMP}/uploaded.tar.zst"; }
  cache_cocoapods_save 2>/dev/null
  [ "${S3_CACHE_SAVE_COCOAPODS}" = uploaded ]
  tar --zstd -tf "${TEST_TMP}/uploaded.tar.zst" | grep -q "^Pods/C/c.h"
}

@test "restore extracts into the source dir for a nested directory" {
  mkdir -p "${SEED}/app/ios/Pods"
  echo p >"${SEED}/app/ios/Pods/p.h"
  archive_create "${TEST_TMP}/nested.tar.zst" "${SEED}" app/ios/Pods 2>/dev/null
  export cocoapods_dir="app/ios/Pods"
  cfg_init
  export STUB_AWS_GET_FILE="${TEST_TMP}/nested.tar.zst"
  cache_cocoapods_restore 2>/dev/null
  [ -f "${BITRISE_SOURCE_DIR}/app/ios/Pods/p.h" ]
}

@test "an empty directory is skipped on restore and save" {
  make_pods
  export cocoapods_dir=""
  cfg_init
  export STUB_AWS_GET_FILE="${TEST_TMP}/served.tar.zst"
  cache_cocoapods_restore 2>"${TEST_TMP}/err"
  [ "${S3_CACHE_RESULT_COCOAPODS}" = skipped ]
  grep -qi "empty" "${TEST_TMP}/err"
  cache_cocoapods_save 2>/dev/null
  [ "${S3_CACHE_SAVE_COCOAPODS}" = skipped ]
  refute_called "aws"
}

@test "dot, the source directory itself and a trailing-slash source are skipped" {
  make_pods
  local d
  for d in "." "./" "${BITRISE_SOURCE_DIR}" "${BITRISE_SOURCE_DIR}/" "ios/.." "/"; do
    export cocoapods_dir="${d}"
    cfg_init
    : >"${STUB_LOG}"
    cache_cocoapods_restore 2>/dev/null
    [ "${S3_CACHE_RESULT_COCOAPODS}" = skipped ]
    cache_cocoapods_save 2>/dev/null
    [ "${S3_CACHE_SAVE_COCOAPODS}" = skipped ]
    refute_called "aws"
  done
}

@test "a relative directory escaping the source directory is skipped" {
  mkdir -p "${TEST_TMP}/x/Pods"
  export cocoapods_dir="../x/Pods"
  cfg_init
  export STUB_AWS_GET_FILE="${TEST_TMP}/served.tar.zst"
  cache_cocoapods_restore 2>"${TEST_TMP}/err"
  [ "${S3_CACHE_RESULT_COCOAPODS}" = skipped ]
  cache_cocoapods_save 2>/dev/null
  [ "${S3_CACHE_SAVE_COCOAPODS}" = skipped ]
  refute_called "aws"
}

@test "a leading ./ is normalised to the plain layout" {
  make_pods
  export cocoapods_dir="./ios/Pods"
  export cocoapods_lockfile="./ios/Podfile.lock"
  cfg_init
  storage_put() { cp "$1" "${TEST_TMP}/uploaded.tar.zst"; }
  cache_cocoapods_save 2>/dev/null
  [ "${S3_CACHE_SAVE_COCOAPODS}" = uploaded ]
  tar --zstd -tf "${TEST_TMP}/uploaded.tar.zst" | grep -q "^ios/Pods/B/b.h"
}

@test "a source directory with a trailing slash still saves" {
  make_pods
  export BITRISE_SOURCE_DIR="${BITRISE_SOURCE_DIR}/"
  cfg_init
  storage_put() { cp "$1" "${TEST_TMP}/uploaded.tar.zst"; }
  cache_cocoapods_save 2>/dev/null
  [ "${S3_CACHE_SAVE_COCOAPODS}" = uploaded ]
  tar --zstd -tf "${TEST_TMP}/uploaded.tar.zst" | grep -q "^ios/Pods/B/b.h"
}
