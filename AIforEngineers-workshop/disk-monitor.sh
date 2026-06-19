#!/usr/bin/env bash
set -euo pipefail

readonly CHECK_MOUNT="/"
readonly CHECK_INTERVAL=300 # 5 minutes
readonly THRESHOLD_NOTIFY=5
readonly THRESHOLD_ALERT=90
readonly APP_LOG_DIR="/var/log"
readonly ARCHIVE_DIR="/var/log/archive"
readonly LOG_FILE="/var/log/disk-monitor.log"
readonly PIDFILE="/tmp/disk-monitor.pid"

DRY_RUN=false
RUN_FOREVER=false
ONCE=false
EXPLICIT_RUN=false
ROLLBACK_PERFORMED=false
ROLLBACK_REQUIRED=false
MANIFEST="/tmp/disk-monitor.moved.manifest"

function log_message() {
  local msg="$1"
  local ts
  ts="$(date --iso-8601=seconds)"
  local line
  line="${ts} ${msg}"

  if [ "$(id -u)" -eq 0 ]; then
    printf '%s\n' "$line" >> "$LOG_FILE"
  else
    printf '%s\n' "$line" | sudo tee -a "$LOG_FILE" >/dev/null
  fi

  if [ "${DRY_RUN:-false}" = true ]; then
    printf '%s\n' "DRY RUN: ${line}"
  fi
}

function ensure_single_instance() {
  if [ -f "$PIDFILE" ]; then
    local existing
    existing="$(<"$PIDFILE")"
    if [ -n "$existing" ] && kill -0 "$existing" 2>/dev/null; then
      log_message "Monitor already running with PID $existing"
      printf 'Monitor already running with PID %s\n' "$existing" >&2
      exit 1
    fi
    rm -f "$PIDFILE"
  fi
  printf '%s\n' "$$" > "$PIDFILE"
}

function cleanup_pid() {
  if [ -f "$PIDFILE" ]; then
    rm -f "$PIDFILE"
  fi
}

function rollback() {
  if [ "$ROLLBACK_PERFORMED" = true ]; then
    return 0
  fi
  ROLLBACK_PERFORMED=true
  log_message "Rollback triggered: attempting to restore moved files from manifest $MANIFEST"

  if [ ! -f "$MANIFEST" ]; then
    log_message "No manifest found; nothing to rollback"
    return 0
  fi

  while IFS='|' read -r orig archive size; do
    if [ -z "$orig" ] || [ -z "$archive" ]; then
      continue
    fi
    if [ "${DRY_RUN:-false}" = true ]; then
      log_message "DRY RUN: would restore $archive -> $orig"
      continue
    fi
    if [ ! -f "$archive" ]; then
      log_message "Archive missing for $orig: $archive"
      continue
    fi
    log_message "Restoring $archive -> $orig"
    if [ "$(id -u)" -eq 0 ]; then
      gzip -dc "$archive" > "$orig"
    else
      sudo gzip -dc "$archive" | sudo tee "$orig" >/dev/null
    fi
  done < "$MANIFEST"

  cleanup_pid
}

function check_archive_space() {
  local files_to_check=("$@")
  local total=0
  for f in "${files_to_check[@]}"; do
    if [ -f "$f" ]; then
      local s
      s=$(stat -c%s "$f")
      total=$((total + s))
    fi
  done

  # Ensure archive dir exists (or will exist on same filesystem)
  if [ "${DRY_RUN:-false}" = true ]; then
    log_message "DRY RUN: would ensure archive directory $ARCHIVE_DIR exists and has at least $total bytes free"
    return 0
  fi

  if [ "$(id -u)" -eq 0 ]; then
    sudo mkdir -p "$ARCHIVE_DIR"
  else
    sudo mkdir -p "$ARCHIVE_DIR"
  fi

  local avail
  avail=$(df --output=avail -B1 "$ARCHIVE_DIR" 2>/dev/null | tail -n1 || echo 0)
  if [ -z "$avail" ]; then
    avail=0
  fi

  if [ "$avail" -lt "$total" ]; then
    log_message "Not enough space in $(dirname "$ARCHIVE_DIR") for archives: need ${total} bytes, have ${avail} bytes"
    return 1
  fi
  return 0
}

function compress_and_archive() {
  local files=("$@")
  if [ "${#files[@]}" -eq 0 ]; then
    log_message "No files to compress"
    return 0
  fi

  # check space
  if ! check_archive_space "${files[@]}"; then
    log_message "Insufficient archive space; aborting compression"
    return 1
  fi

  : > "$MANIFEST"

  local total_reclaimed=0
  for f in "${files[@]}"; do
    if [ ! -f "$f" ]; then
      continue
    fi
    local base archive size
    base="$(basename "$f")"
    archive="$ARCHIVE_DIR/${base}.gz"
    size=$(stat -c%s "$f")

    if [ "${DRY_RUN:-false}" = true ]; then
      log_message "DRY RUN: would compress $f -> $archive (original ${size} bytes)"
      printf '%s|%s|%s\n' "$f" "$archive" "$size" >> "$MANIFEST"
      continue
    fi

    if [ -f "$archive" ]; then
      log_message "Archive already exists for $f: $archive; skipping"
      continue
    fi

    log_message "Compressing $f -> $archive"
    if [ "$(id -u)" -eq 0 ]; then
      gzip -c "$f" > "$archive"
      sudo chmod --reference="$f" "$archive" || true
    else
      sudo bash -c "gzip -c \"$f\" > \"$archive\""
      sudo chmod --reference="$f" "$archive" || true
    fi

    # Truncate original file (do not delete) to free space
    log_message "Truncating original $f to preserve inode but free space"
    if [ "$(id -u)" -eq 0 ]; then
      : > "$f"
    else
      sudo truncate -s 0 "$f"
    fi

    ROLLBACK_REQUIRED=true

    printf '%s|%s|%s\n' "$f" "$archive" "$size" >> "$MANIFEST"
    total_reclaimed=$((total_reclaimed + size))
  done

  log_message "Compression complete; total bytes accounted: $total_reclaimed"
  return 0
}

function check_disk_and_manage() {
  local usage
  usage=$(df --output=pcent "$CHECK_MOUNT" | tail -n1 | tr -dc '0-9') || usage=0

  log_message "Root usage ${usage}%"

  if [ "$usage" -ge "$THRESHOLD_ALERT" ]; then
    printf 'ALERT: root usage at %s%%\n' "$usage"
  fi

  if [ "$usage" -lt "$THRESHOLD_NOTIFY" ]; then
    return 0
  fi

  if [ ! -d "$APP_LOG_DIR" ]; then
    log_message "Log directory $APP_LOG_DIR does not exist; nothing to archive"
    return 0
  fi

  local files=()
  while IFS= read -r -d '' path; do
    files+=("$path")
  done < <(find "$APP_LOG_DIR" -maxdepth 1 -type f ! -iname '*.gz' -mmin +360 -print0)

  if [ "${#files[@]}" -eq 0 ]; then
    log_message "No log files older than 6 hours in $APP_LOG_DIR"
    return 0
  fi

  compress_and_archive "${files[@]}"
}

function usage() {
  cat <<EOF
Usage: $0 [--dry-run] [--run] [--once] [--help]
  --dry-run   Show actions without performing compression or truncation
  --run       Run monitor loop (daemon)
  --once      Run a single check and exit
  --help      Show this help message

Default without flags: run once and exit.
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
    --help)
      usage
      ;;
    *)
      usage
      ;;
  esac
  shift
done

# If user provided --dry-run without explicit run flag, treat as one-time dry-run
if [ "$DRY_RUN" = true ] && [ "$EXPLICIT_RUN" = false ]; then
  ONCE=true
fi

# Default no-flag behavior: run once and exit
if [ "$EXPLICIT_RUN" = false ] && [ "$DRY_RUN" = false ]; then
  ONCE=true
fi

# If this is a one-time dry-run
if [ "$DRY_RUN" = true ] && [ "$ONCE" = true ]; then
  ensure_single_instance
  log_message "DRY RUN: performing single disk usage check"
  check_disk_and_manage
  cleanup_pid
  exit 0
fi

function on_exit() {
  local code=${EXIT_CODE:-0}
  if [ "$code" -ne 0 ] && [ "$ROLLBACK_REQUIRED" = true ]; then
    rollback
  fi
  cleanup_pid
}

function setup() {
  ensure_single_instance
  trap 'EXIT_CODE=$?; on_exit' EXIT
  trap 'EXIT_CODE=1; exit 1' SIGINT SIGTERM
}

function run_monitor() {
  while true; do
    check_disk_and_manage || log_message "check_disk_and_manage reported non-zero"
    sleep "$CHECK_INTERVAL"
  done
}

# Main execution
setup
if [ "$ONCE" = true ]; then
  check_disk_and_manage
  cleanup_pid
  exit 0
fi

run_monitor
