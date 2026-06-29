FROM postgres:18-trixie

ARG PG_DURABLE_VERSION=0.2.3
ARG PG_MAJOR=18
ARG PG_DURABLE_REPO=sweatybridge/pg_durable
ARG PG_DURABLE_SHA256=e247c3995ba3b8e1537f5f0a30ccef107054b3f0044d380e6c67fa18e4052370

ARG PG_SSH_VERSION=0.1.0
ARG PG_SSH_REPO=sweatybridge/pg_ssh
ARG PG_SSH_SHA256_AMD64=eea4865d29486eb0265015d189bcfe0f9691a8d5a3b7d93468329c8430d9a39c
ARG PG_SSH_SHA256_ARM64=1cee9a58b51af3ccc6d4244544474dda07e90b7a6532fd2701ff4b7b95c5f986

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl; \
    arch="$(dpkg --print-architecture)"; \
    if [ "$arch" != "amd64" ]; then \
      echo "pg_durable release Debian package is currently configured for amd64; got ${arch}" >&2; \
      exit 1; \
    fi; \
    deb="pg-durable-postgresql-${PG_MAJOR}_${PG_DURABLE_VERSION}-1_${arch}.deb"; \
    curl -fsSL \
      -o "/tmp/${deb}" \
      "https://github.com/${PG_DURABLE_REPO}/releases/download/v${PG_DURABLE_VERSION}/${deb}"; \
    echo "${PG_DURABLE_SHA256}  /tmp/${deb}" | sha256sum -c -; \
    apt-get install -y --no-install-recommends "/tmp/${deb}"; \
    rm -f "/tmp/${deb}"; \
    rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    echo "shared_preload_libraries = 'pg_durable'" >> /usr/share/postgresql/postgresql.conf.sample; \
    echo "pg_durable.database = 'postgres'" >> /usr/share/postgresql/postgresql.conf.sample; \
    echo "pg_durable.worker_role = 'postgres'" >> /usr/share/postgresql/postgresql.conf.sample

# pg_ssh runs remote commands over SSH from inside PostgreSQL (ssh.ssh_exec).
# Like pg_durable it ships as a per-arch Debian package, but the asset name
# embeds the distro codename and a "pg<MAJOR>" prefix instead of pg_durable's
# "postgresql-<MAJOR>". No shared_preload_libraries: it is a plain function
# extension with no background worker. libssh2 is statically linked into pg_ssh.so
# (only libssl/libcrypto, already in the base image, are needed at runtime), so
# no extra runtime package is required.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl; \
    arch="$(dpkg --print-architecture)"; \
    . /etc/os-release; codename="$VERSION_CODENAME"; \
    case "$arch" in \
      amd64) sha="${PG_SSH_SHA256_AMD64}" ;; \
      arm64) sha="${PG_SSH_SHA256_ARM64}" ;; \
      *) echo "pg_ssh release has no Debian package for ${arch}" >&2; exit 1 ;; \
    esac; \
    deb="pg-ssh-pg${PG_MAJOR}_${PG_SSH_VERSION}-1_${codename}_${arch}.deb"; \
    curl -fsSL \
      -o "/tmp/${deb}" \
      "https://github.com/${PG_SSH_REPO}/releases/download/v${PG_SSH_VERSION}/${deb}"; \
    echo "${sha}  /tmp/${deb}" | sha256sum -c -; \
    apt-get install -y --no-install-recommends "/tmp/${deb}"; \
    rm -f "/tmp/${deb}"; \
    rm -rf /var/lib/apt/lists/*

COPY docker-entrypoint-initdb.d/ /docker-entrypoint-initdb.d/
