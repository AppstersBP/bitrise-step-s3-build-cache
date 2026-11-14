#!/usr/bin/env bash
# Checks the second round of an end-to-end test (after clean-local.sh, restore, build, save):
#   assert-round2.sh android|ios
# android: Gradle dependencies restored by exact key and refreshed on save, Gradle tasks
#          taken from the build cache, ccache hit rate of at least
#          E2E_MIN_CCACHE_HIT_PERCENT (default below).
# ios:     CocoaPods restored by exact key and refreshed on save.
# Every failed check is printed; the exit status is 1 if any failed.
set -uo pipefail

platform="${1:?usage: assert-round2.sh android|ios}"
# Round 2 on GitHub Actions: 68 of 68 C/C++ compilations were hits (100 %).
min_ccache_hit_percent="${E2E_MIN_CCACHE_HIT_PERCENT:-90}"
failures=0

pass() { printf '[assert-round2] ok: %s\n' "$*"; }
fail() {
  printf '[assert-round2] FAILED: %s\n' "$*"
  failures=$((failures + 1))
}

# check_output NAME EXPECTED
check_output() {
  local value="${!1:-}"
  if [ "${value}" = "$2" ]; then
    pass "$1=${value}"
  else
    fail "$1 is '${value}', expected '$2'"
  fi
}

check_gradle_from_cache() {
  local log="${E2E_LOG_DIR:-}/gradle-round2.log" line count
  if [ ! -f "${log}" ]; then
    fail "Gradle build cache: ${log} does not exist"
    return
  fi
  # "42 actionable tasks: 10 executed, 30 from cache, 2 up-to-date"
  line="$(grep -E 'actionable tasks?:' "${log}" | tail -n 1)"
  count="$(printf '%s' "${line}" | grep -oE '[0-9]+ from cache' | grep -oE '^[0-9]+')"
  if [ -n "${count}" ] && [ "${count}" -gt 0 ]; then
    pass "Gradle build cache: ${line}"
  else
    fail "Gradle build cache: no task was taken from the cache (${line:-no task summary in ${log}})"
  fi
}

check_ccache_hits() {
  local stats line hits total percent
  if ! command -v ccache >/dev/null 2>&1; then
    fail "ccache: not installed"
    return
  fi
  stats="$(ccache --show-stats 2>&1)"
  printf '%s\n' "${stats}"
  if [ -n "${E2E_LOG_DIR:-}" ]; then
    printf '%s\n' "${stats}" >"${E2E_LOG_DIR}/ccache-stats-round2.txt" 2>/dev/null || true
  fi
  # ccache 4: "  Hits:   123 /  130 (94.62%)"
  line="$(printf '%s\n' "${stats}" | grep -E '^[[:space:]]*Hits:' | head -n 1)"
  hits="$(printf '%s' "${line}" | awk '{ print $2 }')"
  total="$(printf '%s' "${line}" | awk '{ print $4 }')"
  case "${hits}/${total}" in
    *[!0-9/]* | /* | */)
      fail "ccache: cannot read the hit count from the statistics (line: '${line}')"
      return
      ;;
  esac
  if [ "${total}" -eq 0 ]; then
    fail "ccache: no cacheable compilation went through ccache"
    return
  fi
  percent=$((hits * 100 / total))
  if [ "${hits}" -gt 0 ] && [ "${percent}" -ge "${min_ccache_hit_percent}" ]; then
    pass "ccache: ${hits} of ${total} compilations were hits (${percent} %, minimum ${min_ccache_hit_percent} %)"
  else
    fail "ccache: ${hits} of ${total} compilations were hits (${percent} %), expected at least ${min_ccache_hit_percent} %"
  fi
}

case "${platform}" in
  android)
    check_output S3_CACHE_RESULT_GRADLE_DEPS exact
    check_output S3_CACHE_SAVE_GRADLE_DEPS refreshed
    check_gradle_from_cache
    check_ccache_hits
    ;;
  ios)
    check_output S3_CACHE_RESULT_COCOAPODS exact
    check_output S3_CACHE_SAVE_COCOAPODS refreshed
    ;;
  *)
    printf '[assert-round2] unknown platform %s (expected android or ios)\n' "${platform}" >&2
    exit 2
    ;;
esac

if [ "${failures}" -gt 0 ]; then
  printf '[assert-round2] %d check(s) failed\n' "${failures}"
  exit 1
fi
printf '[assert-round2] all checks passed\n'
