#!/usr/bin/env bash
set -euo pipefail

# WARNING:
# OpenClaw agents can execute shell commands, read files, and install software.
# Production deployments should isolate agent runtimes, restrict permissions,
# and add approval layers for destructive actions.

log() {
  printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"
}

fail() {
  printf '\nERROR: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

run_as_root() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    fail "This step requires root privileges and sudo is not available: $*"
  fi
}

append_path_if_dir() {
  local dir="$1"
  if [[ -d "$dir" && ":$PATH:" != *":$dir:"* ]]; then
    export PATH="$dir:$PATH"
  fi
}

get_node_major() {
  if ! command -v node >/dev/null 2>&1; then
    printf '0\n'
    return
  fi

  node -p "process.versions.node.split('.')[0]" 2>/dev/null || printf '0\n'
}

ensure_node() {
  local node_major
  node_major="$(get_node_major)"

  if [[ "$node_major" -ge 22 ]]; then
    log "Node.js $(node --version) already satisfies the >=22 requirement"
    return
  fi

  log "Installing Node.js 22 from NodeSource"
  require_cmd curl

  if ! command -v apt-get >/dev/null 2>&1; then
    fail "This script currently supports Ubuntu/Debian environments with apt-get"
  fi

  run_as_root apt-get update
  run_as_root apt-get install -y ca-certificates curl gnupg
  curl -fsSL https://deb.nodesource.com/setup_22.x | run_as_root bash -
  run_as_root apt-get install -y nodejs

  log "Installed Node.js $(node --version)"
}

ensure_openclaw_installed() {
  append_path_if_dir "$HOME/.local/bin"
  append_path_if_dir "$HOME/bin"

  if command -v openclaw >/dev/null 2>&1; then
    log "OpenClaw CLI already present at $(command -v openclaw)"
  else
    log "Installing OpenClaw with the official installer"
    require_cmd curl
    curl -fsSL https://openclaw.ai/install.sh | bash
  fi

  append_path_if_dir "$HOME/.local/bin"
  append_path_if_dir "$HOME/bin"

  command -v openclaw >/dev/null 2>&1 || fail "OpenClaw installation completed, but the CLI is not on PATH"
  log "OpenClaw CLI available at $(command -v openclaw)"
}

verify_openclaw_cli() {
  log "Verifying OpenClaw CLI"
  if ! openclaw --help >/dev/null 2>&1; then
    fail "The OpenClaw CLI failed to run. Check PATH, reinstall with the official installer, and retry."
  fi
}

find_existing_token() {
  local candidate

  if [[ -n "${OPENCLAW_GATEWAY_TOKEN:-}" ]]; then
    printf '%s\n' "${OPENCLAW_GATEWAY_TOKEN}"
    return 0
  fi

  if [[ -n "${OPENCLAW_API_TOKEN:-}" ]]; then
    printf '%s\n' "${OPENCLAW_API_TOKEN}"
    return 0
  fi

  for candidate in \
    "$HOME/.config/openclaw/token" \
    "$HOME/.config/openclaw/api-token" \
    "$HOME/.openclaw/token" \
    "$HOME/.openclaw/api-token"; do
    if [[ -f "$candidate" ]]; then
      sed -n '1p' "$candidate"
      return 0
    fi
  done

  return 1
}

get_gateway_token() {
  local token

  if [[ -n "${OPENCLAW_GATEWAY_TOKEN:-}" ]]; then
    printf '%s\n' "${OPENCLAW_GATEWAY_TOKEN}"
    return 0
  fi

  set +e
  token="$(openclaw config get gateway.auth.token 2>/dev/null | sed -n '1p')"
  local status=$?
  set -e

  if [[ "$status" -eq 0 && -n "$token" && "$token" != "null" && "$token" != "undefined" ]]; then
    printf '%s\n' "$token"
    return 0
  fi

  return 1
}

run_onboarding() {
  local onboard_log="$1"
  local existing_token="${2:-}"

  if [[ -n "$existing_token" ]]; then
    log "Existing OpenClaw token detected; skipping onboarding to avoid overwriting configuration"
    printf 'Using existing token from local environment or config\n' >"$onboard_log"
    return 0
  fi

  log "Running OpenClaw onboarding"
  set +e
  openclaw onboard 2>&1 | tee "$onboard_log"
  local onboard_status=${PIPESTATUS[0]}
  set -e

  if [[ "$onboard_status" -ne 0 ]]; then
    fail "OpenClaw onboarding failed. Review the captured output at $onboard_log"
  fi
}

start_gateway() {
  local gateway_log="$1"
  local pid_file="$2"

  if [[ -f "$pid_file" ]]; then
    local existing_pid
    existing_pid="$(sed -n '1p' "$pid_file" 2>/dev/null || true)"
    if [[ -n "$existing_pid" ]] && kill -0 "$existing_pid" 2>/dev/null; then
      log "OpenClaw gateway already running with PID $existing_pid"
      printf '%s\n' "$existing_pid"
      return 0
    fi
  fi

  log "Starting OpenClaw gateway in the background"
  nohup openclaw gateway >"$gateway_log" 2>&1 &
  local gateway_pid=$!
  printf '%s\n' "$gateway_pid" >"$pid_file"

  sleep 3
  kill -0 "$gateway_pid" 2>/dev/null || fail "OpenClaw gateway exited early. Check $gateway_log"

  printf '%s\n' "$gateway_pid"
}

start_auto_approve_loop() {
  local approval_log="$1"
  (
    local end_time now device_ids device_id
    end_time=$(( $(date +%s) + 1200 ))

    while true; do
      now="$(date +%s)"
      if [[ "$now" -ge "$end_time" ]]; then
        exit 0
      fi

      if openclaw devices list >"$approval_log.tmp" 2>&1; then
        device_ids="$(
          grep -Eo '[[:alnum:]_-]{6,}' "$approval_log.tmp" \
            | awk '!seen[$0]++'
        )"

        for device_id in $device_ids; do
          openclaw devices approve "$device_id" >>"$approval_log" 2>&1 || true
        done
      fi

      cat "$approval_log.tmp" >>"$approval_log" 2>/dev/null || true
      rm -f "$approval_log.tmp"
      sleep 5
    done
  ) >/dev/null 2>&1 &
}

main() {
  local state_dir host_name env_id origin url
  local onboard_log gateway_log approval_log pid_file
  local token existing_token gateway_pid

  state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/openclaw-bootstrap"
  mkdir -p "$state_dir"
  onboard_log="$state_dir/onboard.log"
  gateway_log="$state_dir/gateway.log"
  approval_log="$state_dir/auto-approve.log"
  pid_file="$state_dir/gateway.pid"

  log "Step 1/8: Ensuring Node.js >= 22"
  ensure_node
  log "Confirmed Node version: $(node --version)"

  log "Step 2/8: Ensuring OpenClaw is installed"
  ensure_openclaw_installed

  log "Step 3/8: Verifying OpenClaw CLI availability"
  verify_openclaw_cli

  existing_token="$(find_existing_token || true)"

  log "Step 4/8: Running onboarding flow"
  run_onboarding "$onboard_log" "$existing_token"

  token="$(get_gateway_token || true)"
  if [[ -z "$token" ]]; then
    log "No configured gateway token found; generating one with OpenClaw doctor"
    openclaw doctor --generate-gateway-token >/dev/null
    token="$(get_gateway_token || true)"
  fi
  if [[ -z "$token" ]]; then
    token="${existing_token:-}"
  fi

  log "Step 5/8: Launching the OpenClaw gateway"
  gateway_pid="$(start_gateway "$gateway_log" "$pid_file")"
  log "Gateway is running with PID $gateway_pid"

  log "Step 6/8: Deriving the UI origin from the hostname"
  host_name="$(hostname 2>/dev/null || true)"
  env_id="$(printf '%s\n' "$host_name" | sed -E 's/^brev-([[:alnum:]]+)$/\1/')"

  if [[ -n "$env_id" && "$env_id" != "$host_name" ]]; then
    origin="https://openclaw0-${env_id}.brevlab.com"
  else
    origin="http://localhost:3000"
  fi

  url="${origin}/chat?session=main"

  log "Step 7/8: Starting 20-minute auto-approval loop"
  start_auto_approve_loop "$approval_log"

  log "Step 8/8: Printing connection information"
  printf '\nOpenClaw Gateway Started\n'
  printf '========================\n\n'
  printf 'URL:\n%s\n\n' "$url"
  printf 'API Token:\n%s\n\n' "${token:-Unavailable - review $onboard_log}"
  printf 'Hostname:\n%s\n\n' "${host_name:-unknown}"
  printf 'Origin:\n%s\n' "$origin"
}

main "$@"
