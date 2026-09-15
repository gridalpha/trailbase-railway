# TrailBase on Railway

The published [`trailbase/trailbase`](https://hub.docker.com/r/trailbase/trailbase)
image plus one entrypoint, so that [TrailBase](https://trailbase.io) runs
unattended on [Railway](https://railway.com).

TrailBase is a single-executable Firebase alternative: SQLite, type-safe record
APIs, realtime subscriptions, auth with a built-in UI, a WebAssembly runtime and
an admin dashboard.

## What this repo adds

| | Why |
|---|---|
| root → `su-exec trailbase` in the entrypoint | Railway mounts the volume root-owned; the image runs as an unprivileged user |
| restores `traildepot/wasm/*.wasm` from `/opt/trailbase-seed` | the volume mount hides the auth-UI WASM component the image ships inside the depot |
| writes an empty `server.s3_storage_config {}` into `config.textproto` | TrailBase's env-var config merge skips optional sub-messages that are not already present, so `TRAIL_SERVER_S3_STORAGE_CONFIG_*` is otherwise inert |
| applies `ADMIN_EMAIL` / `ADMIN_PASSWORD` to the auto-created admin | otherwise the only admin password is a random string in the deploy log; a marker on the volume keeps it idempotent |
| binds `[::]` | dual-stack under tokio, so one socket answers Railway's IPv4 health prober and an IPv6-only private-network caller |
| defaults `TRAIL_EMAIL_SMTP_HOST` and the sender address on their shape | a `${{Service.VAR}}` reference renders empty until that service owns a deployment |

## Variables

| Variable | Default | Notes |
|---|---|---|
| `PORT` | `4000` | the address TrailBase binds, as `[::]:$PORT` |
| `DEPOT` | `/app/traildepot` | mount the volume here |
| `ADMIN_EMAIL` | `admin@localhost` | set only if you want a different admin identity |
| `ADMIN_PASSWORD` | — | unset keeps TrailBase's own generated password |
| `TRAIL_SERVER_SITE_URL` | — | `https://<your public domain>`; used for auth emails and OAuth redirects |
| `TRAIL_EMAIL_SMTP_*` | — | `TRAIL_<path through config.proto>`; see below |
| `TRAIL_SERVER_S3_STORAGE_CONFIG_*` | — | `ENDPOINT`, `REGION`, `BUCKET_NAME`, `ACCESS_KEY`, `SECRET_ACCESS_KEY` |
| `RUNTIME_THREADS` | cgroup CPU quota | the app's own override for the WASM runtime pool |

Every scalar field of TrailBase's
[`config.proto`](https://github.com/trailbaseio/trailbase/blob/main/crates/core/proto/config.proto)
is settable as `TRAIL_<UPPER_SNAKE_PATH>`, e.g. `TRAIL_AUTH_DISABLE_PASSWORD_AUTH`
or `TRAIL_SERVER_AUTH_IP_RATE_LIMIT`. Enum fields take their **numeric** value —
`TRAIL_EMAIL_SMTP_ENCRYPTION=1` is `SMTP_ENCRYPTION_NONE`.

## Upstream

- Source: <https://github.com/trailbaseio/trailbase> (OSL-3.0)
- Docs: <https://trailbase.io/documentation/production>
