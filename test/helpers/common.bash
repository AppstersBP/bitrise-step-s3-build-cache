#!/usr/bin/env bash
# Shared bats helpers.

# setup_env: temporary HOME and BITRISE_SOURCE_DIR, stub commands first on PATH,
# an empty $STUB_LOG. Variables are exported so that `run` sees them.
setup_env() {
  local helpers_dir
  helpers_dir="$(cd "${BATS_TEST_DIRNAME}/../helpers" && pwd)"
  TEST_TMP="$(mktemp -d "${BATS_TMPDIR:-/tmp}/s3cache.XXXXXX")"
  export TEST_TMP
  export HOME="${TEST_TMP}/home"
  export BITRISE_SOURCE_DIR="${TEST_TMP}/src"
  export STUB_LOG="${TEST_TMP}/stub.log"
  mkdir -p "${HOME}" "${BITRISE_SOURCE_DIR}"
  : >"${STUB_LOG}"
  export PATH="${helpers_dir}/stubs:${PATH}"
}

# teardown_env: remove the temporary directory created by setup_env.
teardown_env() {
  [ -n "${TEST_TMP:-}" ] && rm -rf "${TEST_TMP}"
  return 0
}

# assert_called PATTERN: some logged stub call line matches the fixed string PATTERN.
assert_called() {
  if ! grep -qF -- "$1" "${STUB_LOG}"; then
    echo "expected a stub call matching: $1" >&2
    echo "recorded calls:" >&2
    cat "${STUB_LOG}" >&2
    return 1
  fi
}

# refute_called PATTERN: no logged stub call line matches the fixed string PATTERN.
refute_called() {
  if grep -qF -- "$1" "${STUB_LOG}"; then
    echo "unexpected stub call matching: $1" >&2
    echo "recorded calls:" >&2
    cat "${STUB_LOG}" >&2
    return 1
  fi
}
