# syntax=docker/dockerfile:1.7
#
# GitLab Optimized: builds this source tree (CE/FOSS mode) into one image
# tuned for small VPSes. Build context is the repository root:
#
#   docker buildx build --platform linux/arm64 -f optimized/Dockerfile -t gitlab-optimized .
#
ARG RUBY_VERSION=3.4.10
ARG NODE_VERSION=22.23.1
ARG GO_VERSION=1.26
ARG DEBIAN_RELEASE=trixie

############################ Go: Gitaly + Workhorse ############################
FROM golang:${GO_VERSION}-${DEBIAN_RELEASE} AS go-build
RUN apt-get update && apt-get install -y --no-install-recommends \
      meson ninja-build pkg-config libcurl4-openssl-dev libssl-dev libpcre2-dev zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src/gitaly
COPY GITALY_SERVER_VERSION /tmp/GITALY_SERVER_VERSION
RUN curl -fsSL "https://gitlab.com/gitlab-org/gitaly/-/archive/$(cat /tmp/GITALY_SERVER_VERSION)/gitaly.tar.gz" \
      | tar xz --strip-components=1
# Bundled git (3 git builds) is embedded into the gitaly binary.
RUN --mount=type=cache,target=/root/.cache/go-build --mount=type=cache,target=/go/pkg/mod \
    make install PREFIX=/opt/gitaly \
    && rm /opt/gitaly/bin/praefect /opt/gitaly/bin/gitaly-blackbox /opt/gitaly/bin/gitaly-debug \
    && strip /opt/gitaly/bin/*

WORKDIR /src/workhorse
COPY workhorse/ ./
RUN --mount=type=cache,target=/root/.cache/go-build --mount=type=cache,target=/go/pkg/mod \
    make install PREFIX=/opt/workhorse

################################# Ruby gems ####################################
FROM ruby:${RUBY_VERSION}-slim-${DEBIAN_RELEASE} AS ruby-build
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential cmake pkg-config git curl ca-certificates \
      libpq-dev libicu-dev libyaml-dev libssl-dev zlib1g-dev libffi-dev \
      libkrb5-dev libgpgme-dev libmagic-dev libre2-dev \
    && rm -rf /var/lib/apt/lists/*

ENV RAILS_ENV=production \
    BUNDLE_DEPLOYMENT=true \
    BUNDLE_WITHOUT="development:test" \
    BUNDLE_JOBS=8 \
    BUNDLE_BUILD__GPGME="--use-system-libraries" \
    BUNDLE_BUILD__RUBY___MAGIC="--use-system-libraries" \
    FOSS_ONLY=1

RUN useradd --create-home --uid 1000 --shell /bin/bash git
WORKDIR /home/git/gitlab

COPY --chown=git:git Gemfile Gemfile.lock ./
COPY --chown=git:git gems/ gems/
COPY --chown=git:git vendor/gems/ vendor/gems/
RUN gem install bundler -v "$(tail -1 Gemfile.lock | tr -d ' ')" --no-document \
    && bundle install \
    && rm -rf /usr/local/bundle/cache vendor/bundle/ruby/*/cache \
    && find vendor/bundle -name '*.o' -delete

################################ Frontend assets ###############################
FROM node:${NODE_VERSION}-${DEBIAN_RELEASE}-slim AS node
FROM ruby-build AS assets
COPY --from=node /usr/local/bin/node /usr/local/bin/node
COPY --from=node /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -s /usr/local/lib/node_modules/corepack/dist/corepack.js /usr/local/bin/corepack \
    && corepack enable

ENV COREPACK_ENABLE_DOWNLOAD_PROMPT=0 \
    NODE_ENV=production \
    FE_SOURCEMAPS=false \
    NODE_OPTIONS=--max-old-space-size=6144 \
    BROWSERSLIST_IGNORE_OLD_DATA=true

COPY --chown=git:git . .
COPY --chown=git:git optimized/config/ /opt/gitlab-optimized/config/
COPY --chown=git:git optimized/docker/render-config.rb /opt/gitlab-optimized/render-config.rb

RUN --mount=type=cache,target=/root/.yarn/berry/cache \
    yarn install --immutable
# Dummy values: asset compilation boots Rails but never connects to the DB.
RUN mkdir -p tmp/cache tmp/pids tmp/sockets/private log \
    && GITLAB_HOST=localhost DB_HOST=localhost DB_PASSWORD=x REDIS_URL=redis://localhost:6379 \
      ruby /opt/gitlab-optimized/render-config.rb \
    && bundle exec rake gitlab:assets:compile \
    && rm -rf node_modules tmp/cache/* log/* config/gitlab.yml config/database.yml \
      config/resque.yml config/cable.yml config/secrets.yml config/puma.rb \
      .gitlab_shell_secret .gitlab_workhorse_secret .gitlab_kas_secret

#################################### Runtime ###################################
FROM ruby:${RUBY_VERSION}-slim-${DEBIAN_RELEASE}
RUN apt-get update && apt-get install -y --no-install-recommends \
      libpq5 libicu76 libyaml-0-2 libgpgme11t64 libmagic1t64 libre2-11 libkrb5-3 libgssapi-krb5-2 \
      libcurl4t64 libpcre2-8-0 zlib1g libjemalloc2 \
      git postgresql-client-17 ca-certificates tzdata curl procps tini \
    && rm -rf /var/lib/apt/lists/*

ENV RAILS_ENV=production \
    BUNDLE_DEPLOYMENT=true \
    BUNDLE_WITHOUT="development:test" \
    FOSS_ONLY=1 \
    SKIP_CLICKHOUSE_MIGRATIONS=true \
    EXECJS_RUNTIME=Disabled

RUN useradd --create-home --uid 1000 --shell /bin/bash git \
    && mkdir -p /data && chown git:git /data
COPY --from=ruby-build /usr/local/bundle /usr/local/bundle
COPY --from=go-build /opt/gitaly/bin/ /opt/gitaly/bin/
COPY --from=go-build /opt/workhorse/bin/ /usr/local/bin/
COPY --from=assets --chown=git:git /home/git/gitlab /home/git/gitlab
COPY --chown=git:git optimized/config/ /opt/gitlab-optimized/config/
COPY --chown=git:git optimized/docker/ /opt/gitlab-optimized/

USER git
WORKDIR /home/git/gitlab
VOLUME /data
EXPOSE 8181
ENTRYPOINT ["/usr/bin/tini", "--", "/opt/gitlab-optimized/entrypoint.sh"]
