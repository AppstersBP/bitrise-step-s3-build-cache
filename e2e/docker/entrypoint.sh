#!/usr/bin/env bash
# Entry point of the build container in e2e/docker/docker-compose.yml: copies the checkout
# mounted read-only at /checkout (without dependencies and build outputs) to a working
# directory inside the container (the image's BITRISE_SOURCE_DIR, which the step reads its
# relative paths against), then runs the given command there through the image's own entry
# point, which loads the shell profile (Node.js and other tools) as on Bitrise.
set -euo pipefail

work="${BITRISE_SOURCE_DIR:-/bitrise/src}"

# The working directory is deleted below. Refuse unless this is the container of
# docker-compose.yml (marker variable set there, /.dockerenv present, checkout mounted).
if [ "${S3_CACHE_E2E_CONTAINER:-}" != true ] || [ ! -f /.dockerenv ] || [ ! -d /checkout ]; then
  echo "[entrypoint] refusing to run outside the container of e2e/docker/docker-compose.yml" >&2
  exit 1
fi
case "${work}" in
  "" | / | /checkout | /checkout/*)
    echo "[entrypoint] refusing to use '${work}' as the working directory" >&2
    exit 1
    ;;
esac
rm -rf "${work}"
mkdir -p "${work}"
tar -C /checkout \
  --exclude=./.git --exclude=node_modules --exclude=build --exclude=.cxx \
  --exclude=.gradle --exclude=.kotlin --exclude=Pods --exclude=_tmp \
  -cf - . | tar -C "${work}" -xf -

# The branch name of the checkout, for the branch-keyed caches.
if [ -z "${BITRISE_GIT_BRANCH:-}" ] && command -v git >/dev/null 2>&1; then
  BITRISE_GIT_BRANCH="$(git -c safe.directory=/checkout -C /checkout rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  export BITRISE_GIT_BRANCH
fi

cd "${work}"
exec /entrypoint.sh "$@"
