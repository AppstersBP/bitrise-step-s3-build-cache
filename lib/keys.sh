#!/usr/bin/env bash
# Cache key helpers.

# key_branch BRANCH: prints BRANCH with every byte outside A-Za-z0-9._- replaced
# by an underscore. Byte-wise (LC_ALL=C) so keys stay identical to existing archives.
key_branch() {
  printf %s "$1" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_'
}

# _key_sha256: prints the SHA-256 of stdin as 64 hex characters.
_key_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | cut -d' ' -f1
  else
    shasum -a 256 | cut -d' ' -f1
  fi
}

# key_hash_files IGNORE_REGEX FILE...: prints the SHA-256 of the files concatenated
# in the given order, without the lines matching IGNORE_REGEX (grep -E).
# Missing files are skipped with a warning; returns 1 if none exists.
key_hash_files() {
  local ignore="$1" file
  shift
  local existing=()
  for file in "$@"; do
    if [ -f "${file}" ]; then
      existing+=("${file}")
    else
      log_warn "key file not found, skipped: ${file}"
    fi
  done
  if [ "${#existing[@]}" -eq 0 ]; then
    log_error "none of the key files exist"
    return 1
  fi
  # Byte-exact pipeline (no command substitution on the data). grep exits 1 when
  # it selects no line, which is fine; any other failure must not produce a key.
  # grep is checked before cat: a grep that fails early makes cat die of SIGPIPE.
  # The hash goes to a temporary file so that nothing is printed on failure.
  local statuses out
  out="$(mktemp)" || return 1
  cat "${existing[@]}" | grep -v -E -- "${ignore}" | _key_sha256 >"${out}"
  statuses=("${PIPESTATUS[@]}")
  if [ "${statuses[1]}" -gt 1 ]; then
    rm -f "${out}"
    log_error "invalid ignore pattern: ${ignore}"
    return 1
  fi
  if [ "${statuses[0]}" -ne 0 ]; then
    rm -f "${out}"
    log_error "cannot read the key files"
    return 1
  fi
  if [ "${statuses[2]}" -ne 0 ]; then
    rm -f "${out}"
    log_error "cannot compute the SHA-256"
    return 1
  fi
  cat "${out}"
  rm -f "${out}"
}
