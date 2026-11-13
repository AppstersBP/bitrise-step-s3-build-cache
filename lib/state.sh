#!/usr/bin/env bash
# envman exports: step outputs and restore -> save state.

# _state_export KEY VALUE: envman add (for later steps) and export (this shell).
_state_export() {
  local key="$1" value="$2"
  envman add --key "${key}" --value "${value}" || {
    log_error "envman could not set ${key}"
    return 1
  }
  export "${key}=${value}"
}

# _state_id CACHE_ID: upper-case, '-' -> '_'.
_state_id() {
  printf '%s' "$1" | tr 'a-z-' 'A-Z_'
}

# state_set NAME VALUE
state_set() {
  _state_export "S3_CACHE_STATE_$1" "$2"
}

# state_get NAME: prints the value or nothing.
state_get() {
  local var="S3_CACHE_STATE_$1"
  printf '%s' "${!var:-}"
}

# out_result CACHE_ID exact|fallback|none|skipped
out_result() {
  case "$2" in
    exact | fallback | none | skipped) ;;
    *)
      log_error "out_result: invalid value '$2' for $1"
      return 1
      ;;
  esac
  _state_export "S3_CACHE_RESULT_$(_state_id "$1")" "$2"
}

# out_save CACHE_ID uploaded|refreshed|skipped|failed
out_save() {
  case "$2" in
    uploaded | refreshed | skipped | failed) ;;
    *)
      log_error "out_save: invalid value '$2' for $1"
      return 1
      ;;
  esac
  _state_export "S3_CACHE_SAVE_$(_state_id "$1")" "$2"
}
