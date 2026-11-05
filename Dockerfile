# VectorChord on top of the official postgres image, so Postgres patch
# releases don't depend on TensorChord rebuilding their image.
#
# Keep the Debian suffix (-bookworm / -trixie) equal to what your current
# container runs: changing it changes glibc, and with it the collations
# your text indexes were built with.
#
# The pgN in the vchord-scratch tag must match the postgres major version.

FROM tensorchord/vchord-scratch:pg18-v1.1.1 AS vchord

FROM postgres:18.6-bookworm

# PG_MAJOR is set by the postgres base image. pgvector and PostGIS come from
# the PGDG apt repo that the base image already has configured.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      "postgresql-${PG_MAJOR}-pgvector" \
      "postgresql-${PG_MAJOR}-postgis-3" \
      "postgresql-${PG_MAJOR}-postgis-3-scripts" \
 && rm -rf /var/lib/apt/lists/*

COPY --from=vchord / /

CMD ["postgres", "-c", "shared_preload_libraries=vchord,vector"]