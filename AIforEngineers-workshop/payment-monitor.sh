#!/usr/bin/env bash
set -euo pipefail

readonly CHECK_URL="http://localhost:80"
readonly APACHE_SERVICE="apache2"
readonly LOG_FILE="/var/log/payment-monitor.log"
readonly PIDFILE="/tmp/payment-monitor.pid"
readonly SLEEP_INTERVAL=30

RUN_FOREVER=true
ONCE=false
EXPLICIT_RUN=false

DRY_RUN=false
MONITOR_RUNNING=true
ROLLBACK_PERFORMED=false
original_service_state="unknown"

function log_message() {
  local message="$1"
  local timestamp
  timestamp="$(date --iso-8601=seconds)"
  local line
  line="$(printf '%s %s\n' "$timestamp" "$message")"

  # In dry-run mode, print to stdout and don't invoke sudo
  if [ "${DRY_RUN:-false}" = true ]; then
    printf '%s' "$line"
    return 0
  fi

  # If running as root, append directly. Otherwise use sudo tee (may prompt).
  if [ "$(id -u)" -eq 0 ]; then
    printf '%s' "$line" >> "$LOG_FILE"
  else
    printf '%s' "$line" | sudo tee -a "$LOG_FILE" >/dev/null
  fi
}

function ensure_single_instance() {
  if [ -f "$PIDFILE" ]; then
    local existing_pid
    existing_pid="$(<"$PIDFILE")"
    if [ -n "$existing_pid" ] && kill -0 "$existing_pid" 2>/dev/null; then
      log_message "Monitor already running with PID $existing_pid"
      printf 'Monitor already running with PID %s\n' "$existing_pid" >&2
      exit 1
    fi
    rm -f "$PIDFILE"
  fi
  printf '%s\n' "$$" > "$PIDFILE"
}

function capture_thread_dump() {
  if [ "$DRY_RUN" = true ]; then
    log_message "DRY RUN: would capture apache thread dump before restart"
    return 0
  fi

  log_message "Capturing apache thread dump"
  if sudo apachectl fullstatus >/dev/null 2>&1; then
    sudo apachectl fullstatus 2>&1 | sudo tee -a "$LOG_FILE" >/dev/null
  else
    log_message "apachectl fullstatus unavailable; capturing apache2 thread list"
    sudo ps -eLf | grep '[a]pache2' | sudo tee -a "$LOG_FILE" >/dev/null
  fi
}

function restart_apache() {
  if [ "$DRY_RUN" = true ]; then
    log_message "DRY RUN: would restart $APACHE_SERVICE"
    return 0
  fi

  capture_thread_dump
  log_message "Restarting $APACHE_SERVICE service"
  sudo systemctl restart "$APACHE_SERVICE"
  log_message "$APACHE_SERVICE restarted"
}

function rollback() {
  if [ "$ROLLBACK_PERFORMED" = true ]; then
    return 0
  fi

  ROLLBACK_PERFORMED=true
  MONITOR_RUNNING=false
  log_message "Rollback triggered: stopping monitor loop and restoring original $APACHE_SERVICE state"

  if [ -f "$PIDFILE" ]; then
    rm -f "$PIDFILE"
  fi

  if [ "$original_service_state" = "unknown" ]; then
    log_message "Original service state unknown; skipping restore"
    return 0
  fi

  local current_state
  if [ "$(id -u)" -eq 0 ]; then
    current_state="$(systemctl is-active "$APACHE_SERVICE" || true)"
  else
    current_state="$(systemctl is-active "$APACHE_SERVICE" 2>/dev/null || true)"
  fi

  if [ "$original_service_state" = "active" ] && [ "$current_state" != "active" ]; then
    log_message "Restoring $APACHE_SERVICE to active state"
    if [ "$DRY_RUN" = true ]; then
      log_message "DRY RUN: would start $APACHE_SERVICE"
    else
      sudo systemctl start "$APACHE_SERVICE"
    fi
  elif [ "$original_service_state" = "inactive" ] && [ "$current_state" = "active" ]; then
    log_message "Restoring $APACHE_SERVICE to inactive state"
    if [ "$DRY_RUN" = true ]; then
      log_message "DRY RUN: would stop $APACHE_SERVICE"
    else
      sudo systemctl stop "$APACHE_SERVICE"
    fi
  else
    log_message "No original service state restore needed; original state was $original_service_state and current state is $current_state"
  fi
}

function check_health() {
  local status
  status="$(curl -sS -o /dev/null -w '%{http_code}' "$CHECK_URL" || echo '000')"

  if [ "$status" != "200" ]; then
    log_message "Health check failed with HTTP status $status"
    restart_apache
  else
    log_message "Health check OK: HTTP 200"
  fi
}

function setup() {
  if [ "$DRY_RUN" = false ] && [ ! -e "$LOG_FILE" ]; then
    sudo touch "$LOG_FILE"
  fi

  ensure_single_instance
  if [ "$DRY_RUN" = true ]; then
    if [ "$(id -u)" -eq 0 ]; then
      original_service_state="$(systemctl is-active "$APACHE_SERVICE" || echo inactive)"
    else
      original_service_state="$(systemctl is-active "$APACHE_SERVICE" 2>/dev/null || echo unknown)"
    fi
  else
    original_service_state="$(sudo systemctl is-active "$APACHE_SERVICE" || echo inactive)"
  fi
  log_message "Starting payment monitor; original $APACHE_SERVICE state is $original_service_state"

  trap 'MONITOR_RUNNING=false' SIGINT SIGTERM
  trap rollback EXIT
}

function run_monitor() {
  while [ "$MONITOR_RUNNING" = true ]; do
    check_health
    sleep "$SLEEP_INTERVAL"
  done
}

function usage() {
  cat <<EOF
Usage: $0 [--dry-run] [--run] [--once] [--help]
  --dry-run   Print actions without restarting apache or modifying service state
  --run       Run monitor loop (daemon). Default when no flags provided.
  --once      Run a single health check and exit.
  --help      Show this help message.
EOF
  exit 1
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      ;;
    --run)
      RUN_FOREVER=true
      EXPLICIT_RUN=true
      ;;
    --once)
      RUN_FOREVER=false
      ONCE=true
      EXPLICIT_RUN=true
      ;;
    *)
      usage
      ;;
  esac
  shift
done

# If user provided --dry-run without explicitly asking to run the daemon,
# treat it as a single check and exit. If --run was provided as well, run
# the daemon in dry-run mode.
if [ "$DRY_RUN" = true ] && [ "$EXPLICIT_RUN" = false ]; then
  RUN_FOREVER=false
  ONCE=true
fi

# If this is a single-run dry-run, perform one check and exit.
if [ "$DRY_RUN" = true ] && [ "$RUN_FOREVER" = false ]; then
  if [ "$DRY_RUN" = false ] && [ ! -e "$LOG_FILE" ]; then
    sudo touch "$LOG_FILE"
  fi
  ensure_single_instance
  log_message "DRY RUN: performing single health check"
  check_health
  if [ -f "$PIDFILE" ]; then
    rm -f "$PIDFILE"
  fi
  exit 0
fi

setup
run_monitor
