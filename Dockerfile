# TrailBase on Railway.
#
# The published image is fine as-is for `docker run`, but three things have to
# happen on Railway before `trail` starts:
#
#   1. Railway mounts the volume at /app/traildepot root-owned, while the image
#      runs as the unprivileged `trailbase` user. The entrypoint therefore has
#      to start as root, take ownership and drop back.
#   2. That mount hides the auth-UI WASM component the image ships inside
#      /app/traildepot/wasm/, so a pristine copy is kept outside the mount and
#      restored on every boot.
#   3. `server.s3_storage_config` is an optional sub-message and TrailBase's
#      env-var config merge skips sub-messages that are not already present in
#      config.textproto, so the empty block has to be written into the file
#      before TRAIL_SERVER_S3_STORAGE_CONFIG_* can take effect.
#
# Nothing here is a fork of TrailBase: it is the published image plus one
# entrypoint.
FROM trailbase/trailbase:latest

# `RUN`/`COPY` inherit the base image's USER, which is `trailbase`.
USER root

# su-exec drops privileges again after the volume has been prepared. BusyBox
# builds setpriv capabilities-only, so it cannot be used here.
RUN apk add --no-cache su-exec

# Keep the depot content the image ships where the volume mount cannot hide it.
RUN mkdir -p /opt/trailbase-seed \
 && cp -a /app/traildepot/* /opt/trailbase-seed/ \
 && ls /opt/trailbase-seed/wasm/*.wasm > /dev/null

COPY entrypoint.sh /usr/local/bin/railway-entrypoint.sh
RUN chmod 0755 /usr/local/bin/railway-entrypoint.sh \
 && sh -n /usr/local/bin/railway-entrypoint.sh

# Fail the build, rather than the container, if the base image ever stops
# shipping something the entrypoint needs.
RUN for t in su-exec sha256sum awk grep stat cp; do command -v "$t" > /dev/null || { echo "missing: $t"; exit 1; }; done \
 && /app/trail --version

WORKDIR /app

# The inherited ENTRYPOINT is `tini --`, which is kept: Railway's own runtime
# holds PID 1, so TINI_SUBREAPER=1 and TINI_KILL_PROCESS_GROUP=1 are set as
# service variables instead of restating the launcher here.
CMD ["/usr/local/bin/railway-entrypoint.sh"]
