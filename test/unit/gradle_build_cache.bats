load ../helpers/common

setup() {
  setup_env
  S3_CACHE_NO_MAIN=1 source ./step.sh
  export mode=restore caches=gradle-build-cache bucket=b prefix=cache/x region=eu-central-1
  export endpoint=https://m:9005 access_key_id=AKIDEXAMPLE secret_access_key=SECRETVALUE123
  export fallback_branch=main
  export BITRISE_GIT_BRANCH="feat/x"
  unset AWS_CONFIG_FILE AWS_SHARED_CREDENTIALS_FILE
  cfg_init
  storage_init 2>/dev/null
  OBJECT="cache/x/buildcache-gradle-feat_x.tar.zst"
  PROPS="${HOME}/.gradle/gradle.properties"
  # A real archive with a build cache entry, served by the aws stub.
  SEED="${TEST_TMP}/seed"
  mkdir -p "${SEED}/.gradle/caches/build-cache-1"
  echo entry >"${SEED}/.gradle/caches/build-cache-1/entry"
  archive_create "${TEST_TMP}/served.tar.zst" "${SEED}" .gradle/caches/build-cache-1 2>/dev/null
  : >"${STUB_LOG}"
}
teardown() { teardown_env; }

@test "restore exact hit sets result exact and extracts into HOME" {
  export STUB_AWS_GET_FILE="${TEST_TMP}/served.tar.zst"
  run cache_gradle_build_cache_restore
  [ "$status" -eq 0 ]
  cache_gradle_build_cache_restore 2>"${TEST_TMP}/err"
  [ "${S3_CACHE_RESULT_GRADLE_BUILD_CACHE}" = exact ]
  [ -f "${HOME}/.gradle/caches/build-cache-1/entry" ]
  grep -qF "${OBJECT}" "${TEST_TMP}/err"
  ! grep -qF SECRETVALUE123 "${TEST_TMP}/err"
}

@test "restore tries branch, then fallback branch, then newest" {
  export STUB_AWS_LIST_OUT=""
  cache_gradle_build_cache_restore 2>/dev/null
  [ "${S3_CACHE_RESULT_GRADLE_BUILD_CACHE}" = none ]
  order="$(grep -oE 's3://b/cache/x/buildcache-gradle-[A-Za-z_]+\.tar\.zst|--prefix cache/x/buildcache-gradle-' "${STUB_LOG}")"
  expected=$'s3://b/cache/x/buildcache-gradle-feat_x.tar.zst\ns3://b/cache/x/buildcache-gradle-main.tar.zst\n--prefix cache/x/buildcache-gradle-'
  [ "${order}" = "${expected}" ]
}

@test "restore from the fallback branch reports fallback" {
  storage_get() {
    case "$1" in *buildcache-gradle-main.tar.zst) cp "${TEST_TMP}/served.tar.zst" "$2" ;; *) return 1 ;; esac
  }
  cache_gradle_build_cache_restore 2>"${TEST_TMP}/err"
  [ "${S3_CACHE_RESULT_GRADLE_BUILD_CACHE}" = fallback ]
  [ -f "${HOME}/.gradle/caches/build-cache-1/entry" ]
  grep -qF "buildcache-gradle-main.tar.zst" "${TEST_TMP}/err"
}

@test "restore from the newest object reports fallback" {
  export STUB_AWS_LIST_OUT=$'2026-01-01T00:00:00+00:00\tcache/x/buildcache-gradle-other.tar.zst'
  storage_get() {
    case "$1" in *buildcache-gradle-other.tar.zst) cp "${TEST_TMP}/served.tar.zst" "$2" ;; *) return 1 ;; esac
  }
  cache_gradle_build_cache_restore 2>"${TEST_TMP}/err"
  [ "${S3_CACHE_RESULT_GRADLE_BUILD_CACHE}" = fallback ]
  [ -f "${HOME}/.gradle/caches/build-cache-1/entry" ]
  grep -qF "buildcache-gradle-other.tar.zst" "${TEST_TMP}/err"
}

@test "fallback branch equal to the current branch is not requested twice" {
  export fallback_branch="feat/x"
  cfg_init
  export STUB_AWS_LIST_OUT=""
  cache_gradle_build_cache_restore 2>/dev/null
  [ "$(grep -c 's3://b/cache/x/buildcache-gradle-feat_x.tar.zst' "${STUB_LOG}")" -eq 1 ]
}

@test "restore with a failing listing reports none" {
  export STUB_AWS_LIST_EXIT=1
  run cache_gradle_build_cache_restore
  [ "$status" -eq 0 ]
  cache_gradle_build_cache_restore 2>"${TEST_TMP}/err"
  [ "${S3_CACHE_RESULT_GRADLE_BUILD_CACHE}" = none ]
  grep -qi "could not list" "${TEST_TMP}/err"
}

@test "damaged archive is reported and removed" {
  echo "not an archive" >"${TEST_TMP}/bad.tar.zst"
  export STUB_AWS_GET_FILE="${TEST_TMP}/bad.tar.zst"
  export STUB_AWS_LIST_OUT=""
  cache_gradle_build_cache_restore 2>"${TEST_TMP}/err"
  [ "${S3_CACHE_RESULT_GRADLE_BUILD_CACHE}" = none ]
  [ ! -e "${HOME}/.gradle/caches/build-cache-1" ]
  grep -qi "damaged" "${TEST_TMP}/err"
  [ -z "$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 's3-build-cache-gradle-bc*' 2>/dev/null)" ]
}

@test "restore enables the build cache in gradle.properties exactly once" {
  cache_gradle_build_cache_restore 2>/dev/null
  cache_gradle_build_cache_restore 2>/dev/null
  [ "$(grep -c '^org.gradle.caching=true$' "${PROPS}")" -eq 1 ]
}

@test "existing gradle.properties lines are kept" {
  mkdir -p "${HOME}/.gradle"
  printf 'org.gradle.jvmargs=-Xmx4g\nfoo=bar\n' >"${PROPS}"
  cache_gradle_build_cache_restore 2>/dev/null
  grep -qx 'org.gradle.jvmargs=-Xmx4g' "${PROPS}"
  grep -qx 'foo=bar' "${PROPS}"
  grep -qx 'org.gradle.caching=true' "${PROPS}"
}

@test "properties file without a trailing newline gets the line on its own line" {
  mkdir -p "${HOME}/.gradle"
  printf 'foo=bar' >"${PROPS}"
  cache_gradle_build_cache_restore 2>/dev/null
  grep -qx 'foo=bar' "${PROPS}"
  grep -qx 'org.gradle.caching=true' "${PROPS}"
}

@test "an existing org.gradle.caching=false line is replaced, not duplicated" {
  mkdir -p "${HOME}/.gradle"
  printf 'a=1\norg.gradle.caching=false\nb=2\n' >"${PROPS}"
  cache_gradle_build_cache_restore 2>/dev/null
  [ "$(grep -c '^org.gradle.caching=' "${PROPS}")" -eq 1 ]
  grep -qx 'org.gradle.caching=true' "${PROPS}"
  grep -qx 'a=1' "${PROPS}"
  grep -qx 'b=2' "${PROPS}"
}

@test "build cache is enabled even when nothing could be restored" {
  export STUB_AWS_LIST_OUT=""
  cache_gradle_build_cache_restore 2>/dev/null
  [ "${S3_CACHE_RESULT_GRADLE_BUILD_CACHE}" = none ]
  grep -qx 'org.gradle.caching=true' "${PROPS}"
}

@test "build cache is enabled even when the listing fails" {
  export STUB_AWS_LIST_EXIT=1
  cache_gradle_build_cache_restore 2>/dev/null
  grep -qx 'org.gradle.caching=true' "${PROPS}"
}

@test "an unset branch is stored as unknown with a warning" {
  unset BITRISE_GIT_BRANCH
  export STUB_AWS_LIST_OUT=""
  cache_gradle_build_cache_restore 2>"${TEST_TMP}/err"
  assert_called "buildcache-gradle-unknown.tar.zst"
  grep -qi "branch" "${TEST_TMP}/err"
}

@test "save always uploads under the current branch" {
  mkdir -p "${HOME}/.gradle/caches/build-cache-1"
  echo e >"${HOME}/.gradle/caches/build-cache-1/entry"
  storage_put() { cp "$1" "${TEST_TMP}/uploaded.tar.zst"; PUT_KEY="$2"; }
  cache_gradle_build_cache_save 2>"${TEST_TMP}/err"
  [ "${S3_CACHE_SAVE_GRADLE_BUILD_CACHE}" = uploaded ]
  [ "${PUT_KEY}" = "${OBJECT}" ]
  tar --zstd -tf "${TEST_TMP}/uploaded.tar.zst" | grep -q "build-cache-1/entry"
  grep -qF "${OBJECT}" "${TEST_TMP}/err"
}

@test "save uploads even after an exact restore" {
  export STUB_AWS_GET_FILE="${TEST_TMP}/served.tar.zst"
  cache_gradle_build_cache_restore 2>/dev/null
  : >"${STUB_LOG}"
  cache_gradle_build_cache_save 2>/dev/null
  [ "${S3_CACHE_SAVE_GRADLE_BUILD_CACHE}" = uploaded ]
  assert_called "s3://b/${OBJECT}"
  refute_called "copy-object"
}

@test "save reports failed when the upload fails" {
  mkdir -p "${HOME}/.gradle/caches/build-cache-1"
  export STUB_AWS_PUT_EXIT=1
  run cache_gradle_build_cache_save
  [ "$status" -eq 0 ]
  cache_gradle_build_cache_save 2>/dev/null
  [ "${S3_CACHE_SAVE_GRADLE_BUILD_CACHE}" = failed ]
}

@test "save with missing directory skips" {
  cache_gradle_build_cache_save 2>"${TEST_TMP}/err"
  [ "${S3_CACHE_SAVE_GRADLE_BUILD_CACHE}" = skipped ]
  grep -qi "nothing to save" "${TEST_TMP}/err"
  refute_called "aws"
}
