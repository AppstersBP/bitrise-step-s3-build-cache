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

# key_hash_file FILE: prints the SHA-256 of the exact bytes of FILE (no line
# filtering, unlike key_hash_files). Returns 1 if the file cannot be read.
key_hash_file() {
  [ -f "$1" ] && [ -r "$1" ] || return 1
  _key_sha256 <"$1"
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
  # Byte-exact steps through temporary files (no command substitution on the data, and no
  # PIPESTATUS, which differs between bash versions). grep exits 1 when it selects no line,
  # which is fine; any other failure must not produce a key. Nothing is printed on failure.
  local joined filtered out rc
  joined="$(mktemp)" || return 1
  filtered="$(mktemp)" || { rm -f "${joined}"; return 1; }
  out="$(mktemp)" || { rm -f "${joined}" "${filtered}"; return 1; }
  if ! cat "${existing[@]}" >"${joined}"; then
    rm -f "${joined}" "${filtered}" "${out}"
    log_error "cannot read the key files"
    return 1
  fi
  grep -v -E -- "${ignore}" "${joined}" >"${filtered}"
  rc=$?
  if [ "${rc}" -gt 1 ]; then
    rm -f "${joined}" "${filtered}" "${out}"
    log_error "invalid ignore pattern: ${ignore}"
    return 1
  fi
  if ! _key_sha256 <"${filtered}" >"${out}"; then
    rm -f "${joined}" "${filtered}" "${out}"
    log_error "cannot compute the SHA-256"
    return 1
  fi
  rm -f "${joined}" "${filtered}"
  cat "${out}"
  rm -f "${out}"
}
