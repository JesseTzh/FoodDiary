#!/usr/bin/env bash
# Boot the production image on an empty volume, verify the password login flow,
# create an entry, then restart against the same volume and verify persistence.
set -euo pipefail

IMAGE="${CI_IMAGE:-fooddiary-ci:local}"
CONTAINER="${CI_CONTAINER:-fooddiary-ci}"
VOLUME="${CI_VOLUME:-fooddiary-ci-data}"
HOST_PORT="${CI_HOST_PORT:-18080}"
BASE_URL="http://127.0.0.1:${HOST_PORT}"
READY_URL="${BASE_URL}/health/ready"
PASSWORD="ci-password-1234"
COOKIE_JAR="$(mktemp)"

cleanup() {
  local status=$?
  if [[ "$status" -ne 0 ]]; then
    docker logs "$CONTAINER" 2>/dev/null || true
  fi
  docker rm --force "$CONTAINER" 2>/dev/null || true
  docker volume rm "$VOLUME" 2>/dev/null || true
  rm -f "$COOKIE_JAR"
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

# A fresh instance has no password yet and rejects unauthenticated API calls.
STATUS="$(curl --fail --silent --show-error "$BASE_URL/api/v1/auth/status")"
echo "$STATUS" | jq -e '.data.auth_required == false and .data.authenticated == false' > /dev/null
CODE="$(curl --silent --output /dev/null --write-out '%{http_code}' "$BASE_URL/api/v1/entries")"
[[ "$CODE" == "401" ]]

# First visit: set the password, which also logs in and issues the session cookie.
CODE="$(curl --fail --silent --show-error \
  --request POST "$BASE_URL/api/v1/auth/setup" \
  --header 'Content-Type: application/json' \
  --cookie-jar "$COOKIE_JAR" \
  --data "{\"password\":\"$PASSWORD\"}" \
  --output /dev/null --write-out '%{http_code}')"
[[ "$CODE" == "200" ]]
CODE="$(curl --silent --output /dev/null --write-out '%{http_code}' \
  --request POST "$BASE_URL/api/v1/auth/setup" \
  --header 'Content-Type: application/json' \
  --data "{\"password\":\"$PASSWORD\"}")"
[[ "$CODE" == "409" ]]

# Create one entry against the empty data volume, with the session cookie.
TITLE="CI fresh-start $(date -u +%Y%m%dT%H%M%SZ)"
ENTRY_ID="$(
  curl --fail --silent --show-error \
    --request POST "$BASE_URL/api/v1/entries" \
    --header 'Content-Type: application/json' \
    --cookie "$COOKIE_JAR" \
    --data "{\"cooked_on\":\"$(date -u +%F)\",\"title\":\"$TITLE\"}" \
    | jq --raw-output '.data.id'
)"
[[ -n "$ENTRY_ID" ]]

# Restart against the same volume: the password and the entry must survive.
docker rm --force "$CONTAINER"
docker run --detach --name "$CONTAINER" \
  --publish "127.0.0.1:${HOST_PORT}:8080" \
  --volume "$VOLUME:/data" \
  "$IMAGE"
wait_ready 30

# Wrong password is rejected; correct password issues a fresh session.
CODE="$(curl --silent --output /dev/null --write-out '%{http_code}' \
  --request POST "$BASE_URL/api/v1/auth/login" \
  --header 'Content-Type: application/json' \
  --data '{"password":"wrong-password"}')"
[[ "$CODE" == "401" ]]
CODE="$(curl --fail --silent --show-error \
  --request POST "$BASE_URL/api/v1/auth/login" \
  --header 'Content-Type: application/json' \
  --cookie-jar "$COOKIE_JAR" \
  --data "{\"password\":\"$PASSWORD\"}" \
  --output /dev/null --write-out '%{http_code}')"
[[ "$CODE" == "200" ]]

SAVED_TITLE="$(curl --fail --silent --show-error \
  --cookie "$COOKIE_JAR" \
  "$BASE_URL/api/v1/entries/$ENTRY_ID" | jq --raw-output '.data.title')"
[[ "$SAVED_TITLE" == "$TITLE" ]]

echo "fresh-start verified: login flow and entry $ENTRY_ID survived a container restart"
