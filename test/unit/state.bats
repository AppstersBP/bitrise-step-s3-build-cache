load ../helpers/common

setup() {
  setup_env
  S3_CACHE_NO_MAIN=1 source ./step.sh
}
teardown() { teardown_env; }

@test "outputs and state go through envman and the current shell" {
  out_result gradle-deps exact
  assert_called "envman add --key S3_CACHE_RESULT_GRADLE_DEPS --value exact"
  [ "$S3_CACHE_RESULT_GRADLE_DEPS" = exact ]
  state_set GRADLE_DEPS_EXACT_KEY k
  assert_called "envman add --key S3_CACHE_STATE_GRADLE_DEPS_EXACT_KEY --value k"
  [ "$(state_get GRADLE_DEPS_EXACT_KEY)" = k ]
}

@test "save outputs use the cache id upper-cased" {
  out_save gradle-build-cache uploaded
  assert_called "envman add --key S3_CACHE_SAVE_GRADLE_BUILD_CACHE --value uploaded"
  [ "$S3_CACHE_SAVE_GRADLE_BUILD_CACHE" = uploaded ]
}

@test "every allowed result and save value is accepted" {
  for v in exact fallback none skipped; do out_result ccache "$v"; done
  for v in uploaded refreshed skipped failed; do out_save ccache "$v"; done
}

@test "invalid values are rejected without calling envman" {
  run out_result ccache uploaded
  [ "$status" -eq 1 ]
  run out_save ccache exact
  [ "$status" -eq 1 ]
  refute_called "envman"
}

@test "unset state is empty" {
  [ -z "$(state_get NOTHING_HERE)" ]
}

@test "a failing envman fails the call" {
  export STUB_ENVMAN_EXIT=1
  run state_set X y
  [ "$status" -ne 0 ]
}
