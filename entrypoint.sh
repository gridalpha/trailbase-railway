#!/bin/sh
# Prepare the Railway volume, then run TrailBase as the unprivileged user the
# image ships. Runs as root; every `trail` invocation is dropped to `trailbase`.
set -eu

log() { echo "[railway] $*"; }

DEPOT="${DEPOT:-/app/traildepot}"
PORT="${PORT:-4000}"
APP_USER=trailbase
SEED_DIR=/opt/trailbase-seed
MARKER_DIR="$DEPOT/.railway"
CONFIG="$DEPOT/config.textproto"

run_as() { su-exec "$APP_USER:$APP_USER" "$@"; }

log "depot=$DEPOT port=$PORT"

# ---------------------------------------------------------------- volume ------
# The mount arrives root-owned. Re-chown the whole tree only when the mount root
# itself is wrong, which is the first boot; later boots pay nothing.
mkdir -p "$DEPOT" "$DEPOT/wasm" "$MARKER_DIR"
if [ "$(stat -c %U "$DEPOT")" != "$APP_USER" ]; then
  log "taking ownership of $DEPOT"
  chown -R "$APP_USER:$APP_USER" "$DEPOT"
else
  chown "$APP_USER:$APP_USER" "$DEPOT/wasm" "$MARKER_DIR"
fi

# ------------------------------------------------------------ wasm seed -------
# The auth UI (/_/auth/login and friends) is a WASM component the image places
# inside the depot, which the volume mount hides. Restore it on every boot so it
# tracks the binary; operator-installed components have other filenames and are
# left alone.
for f in "$SEED_DIR"/wasm/*.wasm; do
  [ -f "$f" ] || continue
  cp -f "$f" "$DEPOT/wasm/$(basename "$f")"
  chown "$APP_USER:$APP_USER" "$DEPOT/wasm/$(basename "$f")"
  log "restored component $(basename "$f")"
done

# ------------------------------------------------- cross-service defaults -----
# A ${{Service.VAR}} reference renders empty until that service owns a
# deployment, so repair these on their shape rather than trusting them.
case "${TRAIL_SERVER_SITE_URL:-}" in
  "" | http:// | https://)
    log "WARNING: no public domain yet; leaving site_url unset for this boot"
    unset TRAIL_SERVER_SITE_URL
    ;;
esac

case "${TRAIL_EMAIL_SMTP_HOST:-}" in
  "" | :*)
    TRAIL_EMAIL_SMTP_HOST=mailpit.railway.internal
    log "defaulted TRAIL_EMAIL_SMTP_HOST to $TRAIL_EMAIL_SMTP_HOST"
    ;;
esac
export TRAIL_EMAIL_SMTP_HOST

SITE_HOST=$(printf %s "${TRAIL_SERVER_SITE_URL:-}" | sed -e 's#^[a-zA-Z][a-zA-Z0-9+.-]*://##' -e 's#/.*$##')
case "${TRAIL_EMAIL_SENDER_ADDRESS:-}" in
  "" | *@)
    if [ -n "$SITE_HOST" ]; then
      TRAIL_EMAIL_SENDER_ADDRESS="noreply@$SITE_HOST"
      export TRAIL_EMAIL_SENDER_ADDRESS
      log "defaulted TRAIL_EMAIL_SENDER_ADDRESS to $TRAIL_EMAIL_SENDER_ADDRESS"
    else
      unset TRAIL_EMAIL_SENDER_ADDRESS
    fi
    ;;
esac

# TrailBase rejects a sender address with no sender name outright:
# `Config(Invalid("Sender address but missing sender name."))`, before it listens.
if [ -n "${TRAIL_EMAIL_SENDER_ADDRESS:-}" ] && [ -z "${TRAIL_EMAIL_SENDER_NAME:-}" ]; then
  TRAIL_EMAIL_SENDER_NAME=TrailBase
  export TRAIL_EMAIL_SENDER_NAME
  log "defaulted TRAIL_EMAIL_SENDER_NAME to $TRAIL_EMAIL_SENDER_NAME"
fi

# --------------------------------------------------------- first-boot init ----
# Every `trail` subcommand runs the same AppState::init, so a cheap one creates
# and migrates the depot, writes the default config.textproto and creates the
# first admin user. Doing it here rather than inside `run` lets the two steps
# below act on the result before any listener opens.
log "initializing depot"
run_as /app/trail --depot "$DEPOT" admin list

# ------------------------------------------------------- object storage -------
enable_object_storage() {
  bucket="${TRAIL_SERVER_S3_STORAGE_CONFIG_BUCKET_NAME:-}"
  if [ -z "$bucket" ]; then
    log "no object-storage bucket configured; uploads stay on the volume"
    return 0
  fi
  if [ ! -f "$CONFIG" ]; then
    log "WARNING: $CONFIG is missing; object storage not enabled"
    return 0
  fi
  if grep -q 's3_storage_config' "$CONFIG"; then
    log "object storage already enabled in config.textproto"
    return 0
  fi
  # An empty message is written as `server {}` on one line, a populated one as a
  # `server {` block; handle both.
  awk '
    /^server[[:space:]]*\{[[:space:]]*\}[[:space:]]*$/ && !inserted {
      print "server {"; print "  s3_storage_config {"; print "  }"; print "}"; inserted = 1; next
    }
    /^server[[:space:]]*\{[[:space:]]*$/ && !inserted {
      print; print "  s3_storage_config {"; print "  }"; inserted = 1; next
    }
    { print }
  ' "$CONFIG" > "$CONFIG.railway-new"
  if grep -q 's3_storage_config' "$CONFIG.railway-new"; then
    mv "$CONFIG.railway-new" "$CONFIG"
    chown "$APP_USER:$APP_USER" "$CONFIG"
    log "enabled S3 object storage, bucket '$bucket'"
  else
    rm -f "$CONFIG.railway-new"
    log "WARNING: no 'server {' block found in config.textproto; object storage NOT enabled, uploads stay on the volume"
  fi
}
enable_object_storage

# ------------------------------------------------------------ admin user ------
# TrailBase creates `admin@localhost` with a random password on the first boot
# and prints it. Replace it with the operator's credentials before anything
# listens, and stamp the pair so a password later changed in the admin UI is
# never reverted.
seed_admin() {
  email="${ADMIN_EMAIL:-admin@localhost}"

  # TrailBase creates its first admin only while the databases are new, so a
  # first boot that dies *after* creating them (a rejected config, say) leaves a
  # depot with no admin at all and no later boot ever adds one.
  admins=$(run_as /app/trail --depot "$DEPOT" admin list 2>/dev/null | tail -n +2 | grep -c '[^[:space:]]' || true)
  if [ "${admins:-0}" -eq 0 ]; then
    if [ -z "${ADMIN_PASSWORD:-}" ]; then
      log "WARNING: this depot has no admin user and ADMIN_PASSWORD is unset; set it and redeploy"
      return 0
    fi
    log "no admin user in this depot; creating $email"
    # `user add` creates the account already verified.
    run_as /app/trail --depot "$DEPOT" user add "$email" "$ADMIN_PASSWORD" \
      || log "user add failed (account already present?)"
    if run_as /app/trail --depot "$DEPOT" admin promote "$email"; then
      printf '%s' "$(printf '%s' "$email:$ADMIN_PASSWORD" | sha256sum | cut -d' ' -f1)" \
        > "$MARKER_DIR/admin-credentials"
      chown "$APP_USER:$APP_USER" "$MARKER_DIR/admin-credentials"
      log "created admin $email"
    else
      log "WARNING: could not promote $email to admin"
    fi
    return 0
  fi

  if [ -z "${ADMIN_PASSWORD:-}" ]; then
    log "ADMIN_PASSWORD unset; keeping TrailBase's own generated admin password"
    return 0
  fi
  stamp=$(printf '%s' "$email:$ADMIN_PASSWORD" | sha256sum | cut -d' ' -f1)
  marker="$MARKER_DIR/admin-credentials"
  if [ -f "$marker" ] && [ "$(cat "$marker")" = "$stamp" ]; then
    log "admin credentials unchanged; leaving the account alone"
    return 0
  fi

  if [ "$email" != "admin@localhost" ]; then
    run_as /app/trail --depot "$DEPOT" user change-email admin@localhost "$email" \
      || log "admin@localhost not found (already renamed?)"
  fi

  if run_as /app/trail --depot "$DEPOT" user change-password "$email" "$ADMIN_PASSWORD"; then
    :
  elif run_as /app/trail --depot "$DEPOT" user change-password admin@localhost "$ADMIN_PASSWORD"; then
    log "WARNING: applied ADMIN_PASSWORD to admin@localhost, not to $email"
  else
    log "WARNING: could not apply ADMIN_EMAIL/ADMIN_PASSWORD; the admin password printed above still applies"
    return 0
  fi

  printf '%s' "$stamp" > "$marker"
  chown "$APP_USER:$APP_USER" "$marker"
  log "applied ADMIN_EMAIL/ADMIN_PASSWORD to the admin account"
}
seed_admin

# ----------------------------------------------------------------- serve ------
# `[::]` is dual-stack under tokio, so one socket answers both Railway's IPv4
# health prober and the gateway over the IPv6-only private network.
# --runtime-threads is deliberately not passed: Rust's available_parallelism
# reads the cgroup quota, and RUNTIME_THREADS is the app's own override.
log "starting TrailBase on [::]:$PORT"
exec su-exec "$APP_USER:$APP_USER" /app/trail --depot "$DEPOT" run --address "[::]:$PORT"
