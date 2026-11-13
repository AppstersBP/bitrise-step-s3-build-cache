load ../helpers/common

setup() {
  setup_env
  S3_CACHE_NO_MAIN=1 source ./step.sh
  export mode=restore caches=gradle-deps bucket=b prefix=cache/x region=eu-central-1
  export endpoint=https://m:9005 access_key_id=AKIDEXAMPLE secret_access_key=SECRETVALUE123
  export gradle_key_files="build.gradle"
  unset AWS_CONFIG_FILE AWS_SHARED_CREDENTIALS_FILE
  printf 'dependencies { implementation "a:b:1" }\n' >"${BITRISE_SOURCE_DIR}/build.gradle"
  cfg_init
  storage_init 2>/dev/null
  HASH="$(key_hash_files "${CFG_GRADLE_KEY_IGNORE_PATTERN}" "${BITRISE_SOURCE_DIR}/build.gradle" 2>/dev/null)"
  OBJECT="cache/x/gradle-${HASH}.tar.zst"
  # A real archive with Gradle files, served by the aws stub.
  SEED="${TEST_TMP}/seed"
  mkdir -p "${SEED}/.gradle/caches/modules-2" "${SEED}/.gradle/wrapper"
  echo dep >"${SEED}/.gradle/caches/modules-2/dep.jar"
  echo dist >"${SEED}/.gradle/wrapper/dist.zip"
  archive_create "${TEST_TMP}/served.tar.zst" "${SEED}" .gradle/caches .gradle/wrapper 2>/dev/null
  : >"${STUB_LOG}"
}
teardown() { teardown_env; }

@test "restore exact hit sets result exact and remembers the key" {
  export STUB_AWS_GET_FILE="${TEST_TMP}/served.tar.zst"
  run cache_gradle_deps_restore
  [ "$status" -eq 0 ]
  cache_gradle_deps_restore 2>"${TEST_TMP}/err"
  [ "${S3_CACHE_RESULT_GRADLE_DEPS}" = exact ]
  [ "$(state_get GRADLE_DEPS_EXACT_KEY)" = "${OBJECT}" ]
  [ -f "${HOME}/.gradle/caches/modules-2/dep.jar" ]
  [ -f "${HOME}/.gradle/wrapper/dist.zip" ]
  grep -qF "${OBJECT}" "${TEST_TMP}/err"
  ! grep -qF SECRETVALUE123 "${TEST_TMP}/err"
}

@test "restore falls back to the newest gradle- object" {
  export STUB_AWS_LIST_OUT=$'2026-01-01T00:00:00+00:00\tcache/x/gradle-old.tar.zst'
  # Exact download fails (not found); the fallback download succeeds.
  storage_get() {
    [ "$1" != "${OBJECT}" ] && cp "${TEST_TMP}/served.tar.zst" "$2"
  }
  cache_gradle_deps_restore 2>"${TEST_TMP}/err"
  [ "${S3_CACHE_RESULT_GRADLE_DEPS}" = fallback ]
  [ -z "$(state_get GRADLE_DEPS_EXACT_KEY)" ]
  [ -f "${HOME}/.gradle/caches/modules-2/dep.jar" ]
  grep -qF "cache/x/gradle-old.tar.zst" "${TEST_TMP}/err"
}

@test "fallback listing never matches build cache archives" {
  export STUB_AWS_LIST_OUT=""
  cache_gradle_deps_restore 2>/dev/null
  assert_called "--prefix cache/x/gradle-"
  refute_called "--prefix cache/x/buildcache"
  refute_called "--prefix cache/x/gradle-build"
}

@test "restore with nothing stored reports none" {
  cache_gradle_deps_restore 2>/dev/null
  [ "${S3_CACHE_RESULT_GRADLE_DEPS}" = none ]
  [ -z "$(state_get GRADLE_DEPS_EXACT_KEY)" ]
  [ ! -e "${HOME}/.gradle" ]
}

@test "restore with a failing listing reports none" {
  export STUB_AWS_LIST_EXIT=1
  run cache_gradle_deps_restore
  [ "$status" -eq 0 ]
  cache_gradle_deps_restore 2>/dev/null
  [ "${S3_CACHE_RESULT_GRADLE_DEPS}" = none ]
}

@test "restore without any key file is skipped" {
  rm "${BITRISE_SOURCE_DIR}/build.gradle"
  cache_gradle_deps_restore 2>/dev/null
  [ "${S3_CACHE_RESULT_GRADLE_DEPS}" = skipped ]
  refute_called "aws"
}

@test "damaged archive is reported and removed" {
  echo "not an archive" >"${TEST_TMP}/bad.tar.zst"
  export STUB_AWS_GET_FILE="${TEST_TMP}/bad.tar.zst"
  cache_gradle_deps_restore 2>"${TEST_TMP}/err"
  [ "${S3_CACHE_RESULT_GRADLE_DEPS}" = none ]
  [ ! -e "${HOME}/.gradle/caches" ]
  grep -qi "damaged" "${TEST_TMP}/err"
  [ -z "$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 's3-build-cache-fetch*' 2>/dev/null)" ]
}

@test "save after exact hit renews the date and does not upload" {
  mkdir -p "${HOME}/.gradle/caches"
  state_set GRADLE_DEPS_EXACT_KEY "${OBJECT}"
  cache_gradle_deps_save 2>/dev/null
  [ "${S3_CACHE_SAVE_GRADLE_DEPS}" = refreshed ]
  assert_called "copy-object"
  refute_called "s3 cp /tmp"
  refute_called "s3 cp ${TMPDIR:-/tmp}"
}

@test "save after exact hit reports failed when the renewal fails" {
  mkdir -p "${HOME}/.gradle/caches"
  state_set GRADLE_DEPS_EXACT_KEY "${OBJECT}"
  export STUB_AWS_COPY_EXIT=1
  cache_gradle_deps_save 2>/dev/null
  [ "${S3_CACHE_SAVE_GRADLE_DEPS}" = failed ]
}

@test "save after fallback uploads under the new key, excluding build-cache-1" {
  mkdir -p "${HOME}/.gradle/caches/modules-2" "${HOME}/.gradle/caches/build-cache-1" "${HOME}/.gradle/wrapper"
  echo dep >"${HOME}/.gradle/caches/modules-2/dep.jar"
  echo bc >"${HOME}/.gradle/caches/build-cache-1/entry"
  # Capture the uploaded file: the stub does not keep it.
  storage_put() { cp "$1" "${TEST_TMP}/uploaded.tar.zst"; PUT_KEY="$2"; }
  cache_gradle_deps_save 2>/dev/null
  [ "${S3_CACHE_SAVE_GRADLE_DEPS}" = uploaded ]
  [ "${PUT_KEY}" = "${OBJECT}" ]
  listing="$(tar --zstd -tf "${TEST_TMP}/uploaded.tar.zst")"
  grep -q "modules-2/dep.jar" <<<"${listing}"
  ! grep -q "build-cache-1" <<<"${listing}"
}

@test "save uploads through the aws stub" {
  mkdir -p "${HOME}/.gradle/wrapper"
  cache_gradle_deps_save 2>/dev/null
  [ "${S3_CACHE_SAVE_GRADLE_DEPS}" = uploaded ]
  assert_called "s3://b/${OBJECT}"
}

@test "gradle-deps save without restore state uploads" {
  mkdir -p "${HOME}/.gradle/caches"
  echo x >"${HOME}/.gradle/caches/f"
  cache_gradle_deps_save 2>/dev/null
  [ "${S3_CACHE_SAVE_GRADLE_DEPS}" = uploaded ]
  refute_called "copy-object"
}

@test "save reports failed when the upload fails" {
  mkdir -p "${HOME}/.gradle/caches"
  export STUB_AWS_PUT_EXIT=1
  run cache_gradle_deps_save
  [ "$status" -eq 0 ]
  cache_gradle_deps_save 2>/dev/null
  [ "${S3_CACHE_SAVE_GRADLE_DEPS}" = failed ]
}

@test "save with missing directory skips" {
  cache_gradle_deps_save 2>"${TEST_TMP}/err"
  [ "${S3_CACHE_SAVE_GRADLE_DEPS}" = skipped ]
  grep -qi "nothing to save" "${TEST_TMP}/err"
  refute_called "aws"
}

@test "save without any key file is skipped" {
  mkdir -p "${HOME}/.gradle/caches"
  rm "${BITRISE_SOURCE_DIR}/build.gradle"
  cache_gradle_deps_save 2>/dev/null
  [ "${S3_CACHE_SAVE_GRADLE_DEPS}" = skipped ]
  refute_called "aws"
}
