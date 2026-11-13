#!/usr/bin/env bash
# main: validates the configuration, checks the storage and runs the selected caches.
# Only configuration errors fail the step; storage and cache problems never do.

# _main_output CACHE_ID VALUE: set the restore or save output of a cache, depending on the mode.
_main_output() {
  if [ "${CFG_MODE}" = save ]; then
    out_save "$1" "$2"
  else
    out_result "$1" "$2"
  fi
}

# _main_run_cache CACHE_ID: run the restore or save function of one cache in a subshell and
# print the value of its output. A failing function or subshell yields none (restore) or
# failed (save) and is logged. Always returns 0.
_main_run_cache() {
  local id="$1" fn out_var failure value rc=0 tmp
  fn="cache_$(printf '%s' "${id}" | tr '-' '_')_${CFG_MODE}"
  if [ "${CFG_MODE}" = save ]; then
    out_var="S3_CACHE_SAVE_$(_state_id "${id}")"
    failure=failed
  else
    out_var="S3_CACHE_RESULT_$(_state_id "${id}")"
    failure=none
  fi
  tmp="$(mktemp "${TMPDIR:-/tmp}/s3-build-cache-main.XXXXXX")" || tmp=""
  if [ -n "${tmp}" ]; then
    # The output variable is exported inside the subshell; hand its value back through a file.
    (
      "${fn}"
      rc=$?
      printf '%s' "${!out_var:-}" >"${tmp}"
      exit "${rc}"
    ) || rc=$?
    value="$(cat "${tmp}" 2>/dev/null)"
    rm -f "${tmp}"
  else
    value="$(
      (
        "${fn}"
        rc=$?
        printf '%s' "${!out_var:-}"
        exit "${rc}"
      )
    )" || rc=$?
  fi
  if [ "${rc}" -ne 0 ]; then
    log_cache "${id}" "failed unexpectedly (exit status ${rc}), continuing without it"
    _main_output "${id}" "${failure}" || true
    value="${failure}"
  elif [ -z "${value}" ]; then
    log_cache "${id}" "set no result, continuing without it"
    _main_output "${id}" "${failure}" || true
    value="${failure}"
  fi
  printf '%s' "${value}"
}

main() {
  local rc=0 cache verb

  cfg_init
  cfg_validate || rc=$?
  case "${rc}" in
    0) ;;
    2)
      for cache in "${CFG_CACHES[@]}"; do _main_output "${cache}" skipped || true; done
      return 0
      ;;
    *) return 1 ;;
  esac

  storage_init || {
    log_error "Cannot prepare the storage access, continuing without caches"
    for cache in "${CFG_CACHES[@]}"; do _main_output "${cache}" skipped || true; done
    return 0
  }
  if ! storage_reachable; then
    [ "${CFG_MODE}" = save ] && verb=saving || verb=restoring
    log_warn "S3 storage is unreachable at $(storage_endpoint_label) — ${verb} no caches"
    for cache in "${CFG_CACHES[@]}"; do _main_output "${cache}" skipped || true; done
    return 0
  fi

  local summary="" value
  for cache in "${CFG_CACHES[@]}"; do
    value="$(_main_run_cache "${cache}")"
    summary="${summary:+${summary}, }${cache}=${value}"
  done
  log_info "${CFG_MODE}: ${summary}"
  return 0
}
