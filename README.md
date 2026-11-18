<p align="center">
  <img src="optimized/branding/gitlab-optimized-logo.svg" alt="GitLab Optimized logo" width="120">
</p>

<h1 align="center">GitLab Optimized</h1>

<p align="center">
  A fork of GitLab Community Edition tuned to run well on small VPSes.
</p>

---

GitLab Optimized is GitLab CE with changed defaults and a single-image build
that fits on a 2 vCPU server with about 4 GB of free RAM. A fresh instance
idles at about **2.25 GB** in total, including PostgreSQL and Redis. A stock
Omnibus install usually needs 4 GB or more.

## What's different

| Area | Stock GitLab | GitLab Optimized |
| --- | --- | --- |
| Edition | EE | CE (FOSS) |
| Web server (Puma) | master + several worker processes | one process, 4 threads |
| Background jobs (Sidekiq) | 20 threads | 5 threads |
| Housekeeping cron jobs | ~30 run every 1–2 min | 15 slowed to every 5–30 min |
| Memory allocator | glibc | jemalloc with fast decay |
| Gitaly | 100 cached `git cat-file` processes, unlimited clones | 10 cached processes, 2 clones per repo, soft Go heap cap |
| PostgreSQL | 100 connections, parallel queries | 60 connections, no parallel gather, 256 MB buffers |
| Bundled extras | Prometheus, exporters, KAS, Pages, registry | not included |
| Service Ping | on | off |

The full list, with the reasoning behind each change, is in
[`optimized/README.md`](optimized/README.md).

## Quick start

You need Docker with Compose v2 on an `arm64` or `amd64` Linux host, plus a
reverse proxy that handles TLS.

```shell
# 1. Build the image (from the repository root)
docker buildx build --platform linux/arm64 -f optimized/Dockerfile -t gitlab-optimized:latest .

# 2. Configure
cd optimized
cat > .env <<EOF
GITLAB_HOST=gitlab.example.com
DB_PASSWORD=$(openssl rand -hex 24)
EOF

# 3. Start PostgreSQL, Redis and GitLab
docker compose up -d

# 4. Get the initial password for the `root` user
docker compose exec gitlab cat /data/config/initial_root_password
```

The first boot creates the database, which takes a few minutes. GitLab then
listens on `127.0.0.1:8929`. Point your reverse proxy at it, for example with
Caddy:

```caddyfile
gitlab.example.com {
	reverse_proxy 127.0.0.1:8929 {
		flush_interval -1
	}
}
```

To build for `amd64`, change `--platform`. On a small server, build on a
bigger machine and copy the image over:

```shell
docker save gitlab-optimized:latest | gzip -1 | ssh user@server 'gunzip | docker load'
```

## Repository layout

- `optimized/` holds everything specific to the fork: the Dockerfile, the
  tuned configuration, the container entrypoint, the Compose file and the
  branding sources.
- Everything else is GitLab's upstream source, with only minimal branding
  changes. Fork changes are kept in `optimized/` so that new upstream
  releases merge cleanly.

## Limitations

- Git over SSH isn't wired up yet. Use HTTPS with a personal access token.
- Outgoing email isn't configured by default. Set up SMTP before inviting
  users.
- EE-only features aren't available. The `ee/` directory isn't part of this
  repository.

## License

GitLab Optimized is released under the [MIT License](LICENSE), the same as
GitLab Community Edition, which it is based on.

GitLab is a trademark of GitLab Inc. This project is not affiliated with or
endorsed by GitLab Inc.
