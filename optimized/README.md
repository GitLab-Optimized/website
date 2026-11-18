# GitLab Optimized

A build of this GitLab source tree tuned to run on a small VPS (2 vCPU, 4 GB of
RAM free). Everything fork-specific lives in this directory. The upstream source
is left untouched, so pulling new GitLab releases stays a plain merge.

## What's different from stock GitLab

| Area | Upstream default | GitLab Optimized |
| --- | --- | --- |
| Edition | EE | CE (FOSS): `ee/` isn't shipped, so fewer classes load at boot |
| Puma | master + worker processes | single process, 4 threads |
| Sidekiq | 20 threads (`sidekiq-cluster`) | 5 threads |
| Housekeeping cron jobs | ~30 run every 1–2 min | 15 slowed to every 5–30 min |
| Cron polling | dynamic | every 60 s |
| Memory allocator | glibc | jemalloc with fast decay (returns memory to the OS) |
| Gitaly `cat-file` cache | 100 processes | 10 processes |
| Clone/fetch concurrency | unlimited | 2 per repo, others queue |
| Gitaly Go heap | unbounded | `GOMEMLIMIT=300MiB` (soft) |
| Image resizer | many scaler processes | 1 |
| PostgreSQL | 100 connections, parallel queries | 60 connections, no parallel gather, 256 MB buffers |
| Service Ping | on | off |
| Prometheus, exporters, KAS, Pages, registry | bundled (Omnibus) | not included |

## Layout

- `Dockerfile` builds Gitaly (with bundled Git), Workhorse, gems and frontend
  assets into one image. The build context is the repo root.
- `config/` holds the tuned config. `gitlab.overrides.yml` is deep-merged over
  upstream's `config/gitlab.yml.example` at start-up.
- `docker/entrypoint.sh` runs Gitaly, Puma, Sidekiq and Workhorse, and runs DB
  setup or migrations on every start.
- `docker-compose.yml` runs the app together with PostgreSQL 17 and Redis.
- `branding/` holds the source SVGs for the logo and wordmark. The favicons,
  touch icons, PWA icons and email logos under `app/assets/images` and `public/`
  are rendered from them.

## Build

```shell
docker buildx build --platform linux/arm64 -f optimized/Dockerfile -t gitlab-optimized:latest .
```

## Run

```shell
cd optimized
cat > .env <<EOF
GITLAB_HOST=gitlab.example.com
DB_PASSWORD=$(openssl rand -hex 24)
EOF
docker compose up -d
docker compose exec gitlab cat /data/config/initial_root_password   # user: root
```

Workhorse listens on `127.0.0.1:8929`. Put a TLS reverse proxy in front of it,
for example Caddy:

```caddyfile
gitlab.example.com {
	reverse_proxy 127.0.0.1:8929 {
		flush_interval -1
	}
}
```

All state lives in the `data`, `postgres` and `redis` volumes. Back them up
before upgrading.

## Tuning knobs

Set these in `.env`: `PUMA_THREADS` (default 4), `SIDEKIQ_CONCURRENCY` (default 5),
`GITLAB_PORT` (default 8929), `GITLAB_EMAIL_FROM`.

## Not included yet

- Git over SSH. Clone over HTTPS with a personal access token.
- Outgoing email. Configure SMTP before inviting other users.
