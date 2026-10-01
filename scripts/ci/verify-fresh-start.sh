#!/usr/bin/env bash
# Boot the production image on an empty volume, create an entry, then restart against the same volume.
set -euo pipefail

IMAGE="${CI_IMAGE:-fooddiary-ci:local}"
CONTAINER="${CI_CONTAINER:-fooddiary-ci}"
VOLUME="${CI_VOLUME:-fooddiary-ci-data}"
HOST_PORT="${CI_HOST_PORT:-18080}"
BASE_URL="http://127.0.0.1:${HOST_PORT}"
READY_URL="${BASE_URL}/health/ready"

cleanup() {
  local status=$?
  if [[ "$status" -ne 0 ]]; then
    docker logs "$CONTAINER" 2>/dev/null || true
  fi
  docker rm --force "$CONTAINER" 2>/dev/null || true
  docker volume rm "$VOLUME" 2>/dev/null || true
  exit "$status"
}

wait_ready() {
  local attempts="$1"
  local attempt
  for attempt in $(seq 1 "$attempts"); do
    if curl --fail --silent "$READY_URL"; then
      return 0
    fi
    docker inspect --format '{{.State.Running}}' "$CONTAINER" | grep --quiet true
    sleep 1
  done
  return 1
}

trap cleanup EXIT

docker volume create "$VOLUME"

docker run --detach --name "$CONTAINER" \
  --publish "127.0.0.1:${HOST_PORT}:8080" \
  --volume "$VOLUME:/data" \
  "$IMAGE"
wait_ready 60

# The SPA frontend must be baked into the image.
curl --fail --silent --show-error "$BASE_URL/" | grep --quiet FoodDiary

# Create one entry against the empty data volume.
TITLE="CI fresh-start $(date -u +%Y%m%dT%H%M%SZ)"
ENTRY_ID="$(
  curl --fail --silent --show-error \
    --request POST "$BASE_URL/api/v1/entries" \
    --header 'Content-Type: application/json' \
    --data "{\"cooked_on\":\"$(date -u +%F)\",\"title\":\"$TITLE\"}" \
    | jq --raw-output '.data.id'
)"
[[ -n "$ENTRY_ID" ]]

# Restart against the same volume: the entry must survive.
docker rm --force "$CONTAINER"
docker run --detach --name "$CONTAINER" \
  --publish "127.0.0.1:${HOST_PORT}:8080" \
  --volume "$VOLUME:/data" \
  "$IMAGE"
wait_ready 30

SAVED_TITLE="$(curl --fail --silent --show-error "$BASE_URL/api/v1/entries/$ENTRY_ID" | jq --raw-output '.data.title')"
[[ "$SAVED_TITLE" == "$TITLE" ]]

echo "fresh-start verified: entry $ENTRY_ID survived a container restart"
