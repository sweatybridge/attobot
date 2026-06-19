FROM postgres:18-trixie

ARG PG_DURABLE_VERSION=0.2.2
ARG PG_MAJOR=18
ARG PG_DURABLE_REPO=sweatybridge/pg_durable
ARG PG_DURABLE_SHA256=78ff0dc6804608ba7b7fa88849188f2f5c2ddc266d8aaf690c51e15bf26dbe91

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
    echo "pg_durable.worker_role = 'postgres'" >> /usr/share/postgresql/postgresql.conf.sample; \
    echo "pg_durable.enable_superuser_instances = on" >> /usr/share/postgresql/postgresql.conf.sample

COPY docker-entrypoint-initdb.d/ /docker-entrypoint-initdb.d/
