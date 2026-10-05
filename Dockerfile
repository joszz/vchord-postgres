# VectorChord on top of the official postgres image, so Postgres patch
# releases don't depend on TensorChord rebuilding their image.
#
# Keep the Debian suffix (-bookworm / -trixie) equal to what your current
# container runs: changing it changes glibc, and with it the collations
# your text indexes were built with.

FROM tensorchord/vchord-scratch:pg18-v1.1.1 AS vchord

FROM postgres:18.6-bookworm

RUN apt-get update \
 && apt-get install -y --no-install-recommends postgresql-18-pgvector \
 && rm -rf /var/lib/apt/lists/*

COPY --from=vchord / /

CMD ["postgres", "-c", "shared_preload_libraries=vchord,vector"]