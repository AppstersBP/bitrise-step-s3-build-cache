#!/usr/bin/env bash
# S3 access through the AWS CLI (AWS S3, MinIO, Cloudflare R2 and other S3-compatible services).
# shellcheck disable=SC2034 # STORAGE_* globals are used by the functions of this file

STORAGE_ENDPOINT=""
STORAGE_ARGS=()

# storage_init: normalise the endpoint, write a private AWS config and export the AWS settings.
storage_init() {
  local endpoint="${CFG_ENDPOINT:-}"
  while [ "${endpoint}" != "${endpoint%/}" ]; do endpoint="${endpoint%/}"; done
  STORAGE_ENDPOINT="${endpoint}"

  local dir
  dir="$(mktemp -d "${TMPDIR:-/tmp}/s3-build-cache-aws.XXXXXX")" || {
    log_error "Cannot create a temporary directory for the AWS configuration."
    return 1
  }
  chmod 700 "${dir}"
  {
    printf '[default]\n'
    printf 'region = %s\n' "${CFG_REGION}"
    printf 's3 =\n'
    printf '    multipart_threshold = 64MB\n'
    printf '    multipart_chunksize = 64MB\n'
    [ -n "${STORAGE_ENDPOINT}" ] && printf '    addressing_style = path\n'
  } >"${dir}/config"
  : >"${dir}/credentials"

  export AWS_CONFIG_FILE="${dir}/config"
  export AWS_SHARED_CREDENTIALS_FILE="${dir}/credentials"
  export AWS_ACCESS_KEY_ID="${CFG_ACCESS_KEY_ID}"
  export AWS_SECRET_ACCESS_KEY="${CFG_SECRET_ACCESS_KEY}"
  export AWS_DEFAULT_REGION="${CFG_REGION}"
  export AWS_RETRY_MODE=standard
  export AWS_MAX_ATTEMPTS=2
  export AWS_REQUEST_CHECKSUM_CALCULATION=when_required
  export AWS_RESPONSE_CHECKSUM_VALIDATION=when_required
  unset AWS_PROFILE AWS_SESSION_TOKEN

  STORAGE_ARGS=()
  [ -n "${STORAGE_ENDPOINT}" ] && STORAGE_ARGS+=(--endpoint-url "${STORAGE_ENDPOINT}")

  if [ -n "${STORAGE_ENDPOINT}" ]; then
    # shellcheck disable=SC2001 # a regular expression is needed to drop the userinfo part
    log_info "Storage: bucket ${CFG_BUCKET} at $(printf '%s' "${STORAGE_ENDPOINT}" | sed 's#^\([A-Za-z][A-Za-z0-9+.-]*://\)[^/@]*@#\1#') (path-style addressing)"
  else
    log_info "Storage: bucket ${CFG_BUCKET} on AWS S3, region ${CFG_REGION}"
  fi
}

# storage_reachable: 0 if the bucket answers within about 5 seconds (single attempt).
storage_reachable() {
  AWS_MAX_ATTEMPTS=1 aws ${STORAGE_ARGS[@]+"${STORAGE_ARGS[@]}"} --cli-connect-timeout 5 --cli-read-timeout 5 \
    s3api head-bucket --bucket "${CFG_BUCKET}" >/dev/null
}

# storage_object NAME: print the object key <prefix>/NAME.
storage_object() {
  printf '%s/%s\n' "${CFG_PREFIX}" "$1"
}

# storage_get KEY DEST_FILE: download an object. 1 if it is missing or the download fails.
storage_get() {
  aws ${STORAGE_ARGS[@]+"${STORAGE_ARGS[@]}"} --cli-connect-timeout "${CFG_CONNECT_TIMEOUT}" \
    s3 cp --only-show-errors "s3://${CFG_BUCKET}/$1" "$2"
}

# storage_put SRC_FILE KEY: upload a file.
storage_put() {
  aws ${STORAGE_ARGS[@]+"${STORAGE_ARGS[@]}"} --cli-connect-timeout "${CFG_CONNECT_TIMEOUT}" \
    s3 cp --only-show-errors "$1" "s3://${CFG_BUCKET}/$2"
}

# storage_urlencode_path TEXT: percent-encode everything except A-Za-z0-9._-/ (byte-wise).
storage_urlencode_path() {
  local LC_ALL=C text="$1" out="" i ch
  case "${text}" in
    *[!A-Za-z0-9._/-]*) ;;
    *)
      printf '%s' "${text}"
      return 0
      ;;
  esac
  for ((i = 0; i < ${#text}; i++)); do
    ch="${text:i:1}"
    case "${ch}" in
      [A-Za-z0-9._/-]) out+="${ch}" ;;
      *) out+="$(printf '%%%02X' "'${ch}")" ;;
    esac
  done
  printf '%s' "${out}"
}

# storage_touch KEY: refresh LastModified by copying the object onto itself.
storage_touch() {
  local source
  source="${CFG_BUCKET}/$(storage_urlencode_path "$1")"
  aws ${STORAGE_ARGS[@]+"${STORAGE_ARGS[@]}"} --cli-connect-timeout "${CFG_CONNECT_TIMEOUT}" \
    s3api copy-object --bucket "${CFG_BUCKET}" --key "$1" --copy-source "${source}" \
    --metadata-directive REPLACE >/dev/null
}

# storage_latest NAME_PREFIX: print the most recently modified key under <prefix>/NAME_PREFIX,
# nothing if there is none. Returns 1 only if the listing itself fails.
storage_latest() {
  # shellcheck disable=SC2016 # JMESPath backticks are literal
  local result query='sort_by(Contents || `[]`, &LastModified)[-1].Key'
  result="$(aws ${STORAGE_ARGS[@]+"${STORAGE_ARGS[@]}"} --cli-connect-timeout "${CFG_CONNECT_TIMEOUT}" \
    s3api list-objects-v2 --bucket "${CFG_BUCKET}" --prefix "${CFG_PREFIX}/$1" \
    --query "${query}" --output text)" || return 1
  case "${result}" in
    "" | None) ;;
    *) printf '%s\n' "${result}" ;;
  esac
  return 0
}
