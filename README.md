# vchord-postgres

The official [`postgres`](https://hub.docker.com/_/postgres) image with
[VectorChord](https://github.com/tensorchord/VectorChord),
[pgvector](https://github.com/pgvector/pgvector) and
[PostGIS](https://postgis.net/) added, built and published to GHCR by GitHub
Actions.

TensorChord publishes its own `vchord-postgres` image, but a new Postgres patch
release only reaches it once they rebuild. This image starts from the official
`postgres` image instead and copies in the VectorChord files from
`tensorchord/vchord-scratch`. That way Postgres updates go out on our own
schedule.

## What's in the image

| Component | Source | Version |
|---|---|---|
| PostgreSQL | `postgres:18.6-bookworm` | 18.6, Debian 12 (bookworm) |
| VectorChord | `tensorchord/vchord-scratch:pg18-v1.1.1` | 1.1.1 |
| pgvector | `postgresql-18-pgvector` from the PGDG apt repo in the base image | latest when the image is built |
| PostGIS | `postgresql-18-postgis-3` and `-scripts` from the same PGDG repo | latest 3.x when the image is built |

- `shared_preload_libraries=vchord,vector` is set through the image's `CMD`.
  See [Changing server settings](#changing-server-settings) before you override
  `command`.
- PostGIS needs no preloading. The `postgis`, `postgis_raster`,
  `postgis_topology` and `postgis_sfcgal` extensions are available. The
  command-line tools (`shp2pgsql`, `raster2pgsql`) are not included.
- The image is built for `linux/amd64` only.

Everything else behaves the same as the official image: the environment
variables, the `/docker-entrypoint-initdb.d` scripts and the volume layout.

## Tags

Images are pushed to `ghcr.io/joszz/vchord-postgres`.

| Tag | Points to |
|---|---|
| `pg18` | The latest build for Postgres 18. Use this one to receive updates. |
| `18.6-vchord1.1.1` | The latest build of that Postgres and VectorChord version. |

Every build overwrites both tags, including the monthly security rebuild. That
rebuild can bring in newer Debian packages and a newer pgvector. To pin an exact
image, use its digest (`ghcr.io/joszz/vchord-postgres@sha256:...`).

The package is public, so you can pull it without logging in to GHCR.

## Usage

```yaml
services:
  postgres:
    image: ghcr.io/joszz/vchord-postgres:pg18
    restart: unless-stopped
    environment:
      POSTGRES_PASSWORD: change-me
    volumes:
      - pgdata:/var/lib/postgresql
    ports:
      - "5432:5432"

volumes:
  pgdata:
```

From Postgres 18 on, the official image stores data in
`/var/lib/postgresql/18/docker`, and the volume is `/var/lib/postgresql`. Older
images used `/var/lib/postgresql/data`. If your existing volume is mounted at
`/var/lib/postgresql/data`, the container stops with an error about the new
layout. To keep the old layout, keep that mount and set
`PGDATA=/var/lib/postgresql/data`.

Enable the extensions in each database that needs them. `CASCADE` also creates
`vector`, which VectorChord depends on:

```sql
CREATE EXTENSION IF NOT EXISTS vchord CASCADE;

CREATE TABLE items (id bigserial PRIMARY KEY, embedding vector(768));
CREATE INDEX ON items USING vchordrq (embedding vector_cosine_ops);
```

PostGIS is enabled the same way, per database:

```sql
CREATE EXTENSION IF NOT EXISTS postgis;
-- Only if you need them:
CREATE EXTENSION IF NOT EXISTS postgis_raster;
CREATE EXTENSION IF NOT EXISTS postgis_topology;

CREATE TABLE places (id bigserial PRIMARY KEY, geom geometry(Point, 4326));
CREATE INDEX ON places USING gist (geom);
```

To tune `vchordrq` (lists, probes and so on), see the
[VectorChord documentation](https://docs.vectorchord.ai/).

### Changing server settings

The image sets the preload libraries on the command line. Command-line settings
take precedence over `postgresql.conf` and `ALTER SYSTEM`, which has two
consequences:

- **Overriding `command` drops the preload.** VectorChord then fails to load.
  Include the preload setting in your own command:

  ```yaml
  command:
    - postgres
    - -c
    - shared_preload_libraries=vchord,vector
    - -c
    - max_connections=200
  ```

- **`ALTER SYSTEM SET shared_preload_libraries = ...` is ignored.** To add a
  library such as `pg_stat_statements`, extend the `-c
  shared_preload_libraries=...` value in `command` instead.

Other settings (`shared_buffers`, `work_mem` and so on) can be set either with
`ALTER SYSTEM` or with extra `-c` flags.

## Updating

### How updates reach the image

- **Dependabot** checks the two `FROM` lines every week. It opens a PR for each
  new Postgres minor release and each VectorChord release. CI builds and
  smoke-tests the PR without pushing. Merging it publishes the new image.
  Dependabot never proposes a new Postgres major version (see below).
- **A scheduled rebuild** runs on the 1st of every month. It picks up Debian
  security fixes in the base image and the current pgvector and PostGIS
  packages.
- **To rebuild by hand**, open Actions, choose **build**, then **Run workflow**.

### After deploying a new image

A Postgres minor update only needs a container restart.

When VectorChord, pgvector or PostGIS changes version, the new files are in the
image, but each database keeps using the old extension version until you update
it. Run this in every database that uses the extensions:

```sql
SELECT name, installed_version, default_version
FROM pg_available_extensions
WHERE name IN ('vchord', 'vector', 'postgis', 'postgis_raster', 'postgis_topology');

ALTER EXTENSION vector UPDATE;
ALTER EXTENSION vchord UPDATE;
-- Updates postgis and every installed postgis_* extension
SELECT postgis_extensions_upgrade();
```

PostGIS only installs the shared library of its current minor version
(for example `postgis-3.so`), so after an update from 3.7 to 3.8 the old
version's SQL functions point at the new library. Run
`postgis_extensions_upgrade()` soon after deploying, and check the
[PostGIS release notes](https://postgis.net/news/) for anything that requires
extra steps.

Before you update, read the
[VectorChord release notes](https://github.com/tensorchord/VectorChord/releases).
Some releases require a `REINDEX` of `vchordrq` indexes.

### Keep the Debian release fixed

Keep the `-bookworm` suffix on the `postgres` base image. Switching to another
Debian release, such as `-trixie`, changes the glibc version, and with it the
sort order of text under libc collations. B-tree indexes on text columns that
were built under the old order can then return wrong results without raising an
error.

If you do switch, use the same suffix your current container runs. Then reindex
every text index right after the switch.

### Moving to a new Postgres major version

A new major version can't start on an older data directory. Plan this upgrade
as a migration:

1. Wait until TensorChord publishes a `tensorchord/vchord-scratch:pgNN-v…` tag
   for the new major version.
2. Update both `FROM` lines in the [Dockerfile](Dockerfile). The `pgNN` in the
   vchord-scratch tag must match the Postgres major version. CI refuses to build
   if they differ. The pgvector and PostGIS packages and the image tags follow
   automatically.
3. Migrate the data with `pg_dumpall` and a restore into a fresh volume, or
   with `pg_upgrade`.
4. Change consumers from `:pg18` to the new `:pgNN` tag.

### Switching from `tensorchord/vchord-postgres`

1. Check which Debian release the old container runs:
   `docker exec <container> grep VERSION_CODENAME /etc/os-release`.
   If it isn't bookworm, change the suffix in the Dockerfile to match.
2. Make sure both images use the same Postgres major version.
3. Keep the same volume mount (see [Usage](#usage)).
4. Swap the image, then run the extension updates above if the versions
   differ.

## Building locally

```sh
docker build --pull -t vchord-postgres:local .
docker run --rm -e POSTGRES_PASSWORD=test -p 5432:5432 vchord-postgres:local
```

## CI

[`.github/workflows/Build.yml`](.github/workflows/Build.yml) runs on pushes and
PRs that change the Dockerfile or the workflow itself. It also runs on the
monthly schedule and when started by hand. Each run does the following:

1. Reads the Postgres and VectorChord versions from the `FROM` lines, and checks
   that both are for the same major version.
2. Builds the image.
3. Runs a smoke test: it starts the container, creates the extensions, builds a
   `vchordrq` index and checks that a nearest-neighbour query uses it. It then
   creates the PostGIS extensions, runs a coordinate transform and a buffer
   (to check that PROJ and GEOS load), and builds and queries a GiST index.
4. If this is not a PR, logs in to GHCR and pushes `pgNN` and
   `<postgres>-vchord<vchord>`.

If any step fails, nothing is pushed, so a broken build never replaces the
current tags.

## Repository layout

| Path | Purpose |
|---|---|
| [`Dockerfile`](Dockerfile) | The image definition |
| [`.github/workflows/Build.yml`](.github/workflows/Build.yml) | Builds, tests and publishes the image |
| [`.github/dependabot.yml`](.github/dependabot.yml) | Weekly base image updates, monthly GitHub Actions updates |
