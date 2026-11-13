load ../helpers/common

setup() {
  setup_env
  S3_CACHE_NO_MAIN=1 source ./step.sh
  export mode=restore caches=gradle-deps bucket=b prefix=cache/x region=eu-central-1
  export endpoint=https://m:9005 access_key_id=AKIDEXAMPLE secret_access_key=SECRETVALUE123
  export BITRISE_GIT_BRANCH=main
  unset BITRISE_PULL_REQUEST AWS_CONFIG_FILE AWS_SHARED_CREDENTIALS_FILE
}
teardown() { teardown_env; }

@test "configuration error exits 1" {
  export bucket=""
  run main
  [ "$status" -eq 1 ]
  [[ "$output" == *"Missing S3 build cache settings"* ]]
  refute_called "aws"
}

@test "pull request without secrets exits 0 and marks all selected caches skipped" {
  export BITRISE_PULL_REQUEST=7 access_key_id="" secret_access_key="" caches=$'gradle-deps\nccache'
  run main
  [ "$status" -eq 0 ]
  assert_called "S3_CACHE_RESULT_GRADLE_DEPS --value skipped"
  assert_called "S3_CACHE_RESULT_CCACHE --value skipped"
  refute_called "aws"
}

@test "pull request without secrets in save mode sets the save outputs" {
  export BITRISE_PULL_REQUEST=7 access_key_id="" secret_access_key="" mode=save
  run main
  [ "$status" -eq 0 ]
  assert_called "S3_CACHE_SAVE_GRADLE_DEPS --value skipped"
}

@test "unreachable storage logs one line and marks caches skipped" {
  export STUB_AWS_HEAD_BUCKET_EXIT=255 caches=$'gradle-deps\nccache'
  run main
  [ "$status" -eq 0 ]
  [[ "$output" == *"S3 storage is unreachable at https://m:9005 — restoring no caches"* ]]
  assert_called "S3_CACHE_RESULT_GRADLE_DEPS --value skipped"
  assert_called "S3_CACHE_RESULT_CCACHE --value skipped"
  refute_called "s3 cp"
}

@test "unreachable storage message omits credentials in the endpoint" {
  export STUB_AWS_HEAD_BUCKET_EXIT=255 endpoint="https://user:pw@m:9005/"
  run main
  [[ "$output" == *"unreachable at https://m:9005 —"* ]]
  [[ "$output" != *"pw@"* ]]
}

@test "unreachable AWS S3 is named AWS S3" {
  export STUB_AWS_HEAD_BUCKET_EXIT=255 endpoint=""
  run main
  [[ "$output" == *"unreachable at AWS S3 — restoring no caches"* ]]
}

@test "save mode message says saving" {
  export STUB_AWS_HEAD_BUCKET_EXIT=255 mode=save
  run main
  [ "$status" -eq 0 ]
  [[ "$output" == *"S3 storage is unreachable at https://m:9005 — saving no caches"* ]]
  assert_called "S3_CACHE_SAVE_GRADLE_DEPS --value skipped"
}

@test "a failing cache does not stop the others" {
  export caches=$'gradle-deps\nccache'
  cache_gradle_deps_restore() { return 1; }
  cache_ccache_restore() { out_result ccache exact; }
  run main
  [ "$status" -eq 0 ]
  assert_called "S3_CACHE_RESULT_GRADLE_DEPS --value none"
  assert_called "S3_CACHE_RESULT_CCACHE --value exact"
  [[ "$output" == *"restore: gradle-deps=none, ccache=exact"* ]]
}

@test "a cache that exits does not stop the others and a save is marked failed" {
  export caches=$'gradle-deps\nccache' mode=save
  cache_gradle_deps_save() { exit 3; }
  cache_ccache_save() { out_save ccache uploaded; }
  run main
  [ "$status" -eq 0 ]
  assert_called "S3_CACHE_SAVE_GRADLE_DEPS --value failed"
  assert_called "S3_CACHE_SAVE_CCACHE --value uploaded"
  [[ "$output" == *"save: gradle-deps=failed, ccache=uploaded"* ]]
}

@test "a real cache that finds nothing does not fail the step" {
  export STUB_AWS_GET_EXIT=1 caches=gradle-deps
  mkdir -p "${BITRISE_SOURCE_DIR}/android"
  echo x >"${BITRISE_SOURCE_DIR}/android/gradle.properties"
  run main
  [ "$status" -eq 0 ]
  assert_called "S3_CACHE_RESULT_GRADLE_DEPS --value none"
}

@test "only the selected caches run, in the listed order" {
  export caches=$'ccache\ngradle-deps'
  cache_ccache_restore() { echo "ran ccache" >&2; out_result ccache none; }
  cache_gradle_deps_restore() { echo "ran gradle-deps" >&2; out_result gradle-deps none; }
  cache_cocoapods_restore() { echo "ran cocoapods" >&2; }
  cache_gradle_build_cache_restore() { echo "ran gradle-build-cache" >&2; }
  run main
  [ "$status" -eq 0 ]
  [[ "$output" == *"ran ccache"*"ran gradle-deps"* ]]
  [[ "$output" != *"ran cocoapods"* ]]
  [[ "$output" != *"ran gradle-build-cache"* ]]
}

@test "the secret never appears in the output" {
  run main
  [[ "$output" != *SECRETVALUE123* ]]
}
