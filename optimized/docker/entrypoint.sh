#!/usr/bin/env bash
# Runs Gitaly, Puma, Sidekiq and Workhorse in one container. If any of them
# exits, everything is stopped and Docker's restart policy brings it back.
set -euo pipefail

APP=/home/git/gitlab
DATA=/data
cd "$APP"

log() { echo "[gitlab-optimized] $*"; }

# Runtime state survives `docker restart`, and PIDs repeat across boots, so a
# leftover gitaly-<pid> dir or pid file would block startup.
rm -rf /home/git/gitaly-runtime "$APP"/tmp/pids "$APP"/tmp/sockets
mkdir -p "$DATA"/{config,shared,uploads,repositories,backups,log,custom_hooks} \
  /home/git/gitaly-runtime "$APP"/tmp/{pids,cache,sockets/private}
chmod 700 "$DATA/repositories" "$APP/tmp/sockets/private"

# Everything stateful lives in /data so the container itself is disposable.
rm -rf "$APP/log" && ln -sfn "$DATA/log" "$APP/log"
rm -rf "$APP/public/uploads" && ln -sfn "$DATA/uploads" "$APP/public/uploads"

gen_secret() { [ -s "$1" ] || ruby -rsecurerandom -e "print SecureRandom.$2" > "$1"; chmod 600 "$1"; }
gen_secret "$DATA/config/gitlab_shell_secret" "hex(16)"
gen_secret "$DATA/config/gitlab_workhorse_secret" "base64(32)"
ln -sfn "$DATA/config/gitlab_shell_secret" "$APP/.gitlab_shell_secret"
ln -sfn "$DATA/config/gitlab_workhorse_secret" "$APP/.gitlab_workhorse_secret"
ln -sfn "$DATA/config/secrets.yml" "$APP/config/secrets.yml"

if [ ! -s "$DATA/config/initial_root_password" ]; then
  ruby -rsecurerandom -e 'print SecureRandom.alphanumeric(24)' > "$DATA/config/initial_root_password"
  chmod 600 "$DATA/config/initial_root_password"
fi

ruby /opt/gitlab-optimized/render-config.rb

# jemalloc returns freed memory to the OS quickly; plain glibc malloc lets
# long-running Ruby processes fragment and grow.
JEMALLOC=$(ls /usr/lib/*/libjemalloc.so.2 | head -1)
ruby_env=(env LD_PRELOAD="$JEMALLOC" MALLOC_CONF="dirty_decay_ms:1000,muzzy_decay_ms:1000,narenas:2,background_thread:true")

pids=()
shutdown() {
  log "stopping"
  kill -TERM "${pids[@]}" 2>/dev/null || true
  wait || true
}
trap shutdown TERM INT

log "starting gitaly"
GOMEMLIMIT=${GITALY_GOMEMLIMIT:-300MiB} /opt/gitaly/bin/gitaly /home/git/gitaly.toml &
pids+=($!)

log "configuring database (schema load on first boot, migrations afterwards)"
GITLAB_ROOT_PASSWORD=$(cat "$DATA/config/initial_root_password") \
  GITLAB_ROOT_EMAIL=${GITLAB_ROOT_EMAIL:-} \
  "${ruby_env[@]}" bundle exec rake gitlab:db:configure

# Rails rewrites secrets.yml (replacing the symlink) if it ever adds a key.
if [ -f "$APP/config/secrets.yml" ] && [ ! -L "$APP/config/secrets.yml" ]; then
  mv "$APP/config/secrets.yml" "$DATA/config/secrets.yml"
  ln -sfn "$DATA/config/secrets.yml" "$APP/config/secrets.yml"
fi

log "starting puma"
"${ruby_env[@]}" bundle exec puma -C config/puma.rb -e production &
pids+=($!)

log "starting sidekiq (concurrency ${SIDEKIQ_CONCURRENCY:-5})"
"${ruby_env[@]}" bin/sidekiq-cluster -e production -c "${SIDEKIQ_CONCURRENCY:-5}" '*' &
pids+=($!)

log "starting workhorse"
gitlab-workhorse \
  -listenNetwork tcp -listenAddr 0.0.0.0:8181 \
  -authSocket "$APP/tmp/sockets/gitlab.socket" \
  -documentRoot "$APP/public" \
  -secretPath "$APP/.gitlab_workhorse_secret" \
  -config /home/git/workhorse.toml \
  -logFormat json &
pids+=($!)

# Keep logs from slowly filling a small disk.
( while sleep 3600; do
    find "$DATA/log" -name '*.log' -size +100M -exec truncate -s 0 {} + 2>/dev/null || true
  done ) &
pids+=($!)

set +e
wait -n
status=$?
log "a process exited (status $status); stopping the rest"
shutdown
exit 1
