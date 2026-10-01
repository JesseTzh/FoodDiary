#!/usr/bin/env bash
# SSH into the production host and run the remote deploy script.
set -euo pipefail

: "${SSH_HOST:?missing SSH_HOST secret}"
: "${SSH_USER:?missing SSH_USER secret}"
: "${SSH_PRIVATE_KEY:?missing SSH_PRIVATE_KEY secret}"

SSH_PORT="${SSH_PORT:-22}"
SSH_DEPLOY_SCRIPT="${SSH_DEPLOY_SCRIPT:-/root/fooddiary/deploy.sh}"
SSH_DIR="${SSH_DIR:-$HOME/.ssh}"
KEY_FILE="$SSH_DIR/deploy_key"

mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"
printf '%s\n' "$SSH_PRIVATE_KEY" > "$KEY_FILE"
chmod 600 "$KEY_FILE"

if [[ -n "${SSH_KNOWN_HOSTS:-}" ]]; then
  printf '%s\n' "$SSH_KNOWN_HOSTS" > "$SSH_DIR/known_hosts"
else
  ssh-keyscan -p "$SSH_PORT" "$SSH_HOST" >> "$SSH_DIR/known_hosts"
fi

ssh \
  -i "$KEY_FILE" \
  -p "$SSH_PORT" \
  -o IdentitiesOnly=yes \
  -o StrictHostKeyChecking=yes \
  "$SSH_USER@$SSH_HOST" \
  "bash '$SSH_DEPLOY_SCRIPT'"
