load ../helpers/common

setup() {
  setup_env
  S3_CACHE_NO_MAIN=1 source ./step.sh
  unset BITRISE_PULL_REQUEST
  export mode=restore caches=gradle-deps bucket=b prefix=p access_key_id=k secret_access_key=s
}
teardown() { teardown_env; }

@test "all missing settings are listed in one message with the README link" {
  export bucket="" prefix="" access_key_id="" secret_access_key=""
  cfg_init
  run cfg_validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"Missing S3 build cache settings:"* ]]
  [[ "$output" == *"bucket (app variable S3_CACHE_BUCKET)"* ]]
  [[ "$output" == *"prefix (app variable S3_CACHE_PREFIX)"* ]]
  [[ "$output" == *"access_key_id (secret S3_CACHE_ACCESS_KEY_ID)"* ]]
  [[ "$output" == *"secret_access_key (secret S3_CACHE_SECRET_ACCESS_KEY)"* ]]
  [[ "$output" == *"https://github.com/AppstersBP/bitrise-step-s3-build-cache#configuration"* ]]
}

@test "unknown mode and unknown cache are reported together with missing settings" {
  export mode=foo caches=$'gradle-deps\nfoo' bucket=""
  cfg_init
  run cfg_validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"mode: 'foo' is not restore or save"* ]]
  [[ "$output" == *"caches: unknown cache 'foo' (use gradle-deps, gradle-build-cache, ccache, cocoapods)"* ]]
  [[ "$output" == *"bucket (app variable S3_CACHE_BUCKET)"* ]]
}

@test "a valid configuration passes" {
  cfg_init
  run cfg_validate
  [ "$status" -eq 0 ]
}

@test "invalid connect_timeout and empty ccache_max_size are errors" {
  export connect_timeout=abc ccache_max_size=""
  cfg_init
  run cfg_validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"connect_timeout: 'abc' is not a positive integer"* ]]
  [[ "$output" == *"ccache_max_size"* ]]
  export connect_timeout=0 ccache_max_size=5G
  cfg_init
  run cfg_validate
  [ "$status" -eq 1 ]
}

@test "an empty endpoint is valid" {
  export endpoint=""
  cfg_init
  run cfg_validate
  [ "$status" -eq 0 ]
}

@test "pull request build without credentials skips with a notice" {
  export BITRISE_PULL_REQUEST=12 access_key_id="" secret_access_key=""
  cfg_init
  run cfg_validate
  [ "$status" -eq 2 ]
  [[ "$output" == *"secrets are not available to pull request builds"* ]]
  [[ "$output" == *"S3_CACHE_ACCESS_KEY_ID"* ]]
  [[ "$output" == *"S3_CACHE_SECRET_ACCESS_KEY"* ]]
  [[ "$output" == *"Expose for Pull Requests"* ]]
}

@test "pull request build without credentials and other missing settings still skips" {
  export BITRISE_PULL_REQUEST=12 access_key_id="" secret_access_key="" bucket=""
  cfg_init
  run cfg_validate
  [ "$status" -eq 2 ]
}

@test "pull request build with credentials but no bucket is still an error" {
  export BITRISE_PULL_REQUEST=12 bucket=""
  cfg_init
  run cfg_validate
  [ "$status" -eq 1 ]
}

@test "caches input tolerates blank lines, spaces, CRLF and duplicates" {
  export caches=$'gradle-deps\r\n\n  ccache  \ngradle-deps\n'
  cfg_init
  [ "${#CFG_CACHES[@]}" -eq 2 ]
  [ "${CFG_CACHES[0]}" = "gradle-deps" ]
  [ "${CFG_CACHES[1]}" = "ccache" ]
}

@test "gradle_key_files is normalised like caches" {
  export gradle_key_files=$' a.gradle \r\n\nb.properties\na.gradle'
  cfg_init
  [ "${#CFG_GRADLE_KEY_FILES[@]}" -eq 2 ]
  [ "${CFG_GRADLE_KEY_FILES[1]}" = "b.properties" ]
}

@test "region defaults to us-east-1 and prefix loses a trailing slash" {
  export region="" prefix="team/app/"
  cfg_init
  [ "${CFG_REGION}" = "us-east-1" ]
  [ "${CFG_PREFIX}" = "team/app" ]
}

@test "source directory falls back to the working directory" {
  unset BITRISE_SOURCE_DIR
  cfg_init
  [ "${CFG_SOURCE_DIR}" = "${PWD}" ]
}

@test "empty cocoapods settings are errors when cocoapods is selected" {
  export caches=cocoapods cocoapods_dir="" cocoapods_lockfile=""
  cfg_init
  run cfg_validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"cocoapods_lockfile (step input)"* ]]
  [[ "$output" == *"cocoapods_dir (step input)"* ]]
}

@test "empty cocoapods settings are ignored when cocoapods is not selected" {
  export caches=gradle-deps cocoapods_dir="" cocoapods_lockfile=""
  cfg_init
  run cfg_validate
  [ "$status" -eq 0 ]
}

@test "invalid mode or unknown cache is an error even in a pull request build without credentials" {
  export BITRISE_PULL_REQUEST=12 access_key_id="" secret_access_key="" mode=foo caches=$'gradle-deps\nfoo'
  cfg_init
  run cfg_validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"mode: 'foo' is not restore or save"* ]]
  [[ "$output" == *"caches: unknown cache 'foo'"* ]]
}
