---
title: Octop All-in-One
colorFrom: blue
colorTo: gray
sdk: docker
app_port: 7860
suggested_hardware: cpu-basic
pinned: false
---

# Octop All-in-One for Hugging Face Space

This repository packages [TencentCloud/Octop](https://github.com/TencentCloud/Octop)
as one Hugging Face Docker Space for preview use. The Space runs one FastAPI
process that serves both the API and the built React dashboard; it does not add
Nginx, Supervisor, PostgreSQL, Redis, or another application container.

## Deployment target

- GitHub wrapper: <https://github.com/BlueSkyXN/Octop-all-in-one-HFS>
- Live Hugging Face Space: <https://huggingface.co/spaces/BlueSkyXN/Octop-all-in-one-HFS>
- Live app: <https://blueskyxn-octop-all-in-one-hfs.hf.space>
- Space mode: Docker, protected preview, `cpu-basic`
- Public port: `7860`
- Persistent data: private bucket `BlueSkyXN/octop-all-in-one-hfs-data`
  mounted read-write at `/data`

## Source pin

The Docker build fetches and verifies one immutable upstream revision:

```text
repository: https://github.com/TencentCloud/Octop.git
commit:     bfe017adc183cbce7fbd6ca57b050d925a015ee0
version:    0.9.25
```

The full upstream source is not copied into this wrapper repository. The build
verifies both the 40-character Git commit and the version in `pyproject.toml`
before installing Octop.

## Runtime

```text
Hugging Face proxy
        |
        v
Octop / FastAPI :7860
  |- React dashboard at /
  |- API at /api
  `- health at /api/health

/data                                      persistent bucket-backed HOME
  |- .octop/
  |    |- SQLite database and runtime configuration
  |    |- users, credentials, and OAuth state
  |    |- agents, workspaces, chats, and settings
  |    |- browser profiles, knowledge, skills, and plugins
  |    `- daily application backups
  |- .config/ and .local/share/            persistent tool state
  `- other explicit user/tool state

/tmp/octop-cache                           ephemeral caches
/opt/ms-playwright                         image-baked browser binaries
```

The wrapper requires `OCTOP_DEFAULT_PASSWORD`; it does not allow the upstream
well-known fallback password. On first start, the upstream idempotent container
entrypoint initializes `/data/.octop` and then starts `octop run` on port 7860.
Subsequent starts reuse the existing database.

Startup is fail-closed. The wrapper verifies that `/data` is a real mount point
and that `/data/.octop` is writable before it invokes Octop. Starting without a
volume, or with a read-only volume, exits instead of silently creating an
ephemeral database. Runtime `uv`, pip, npm, and XDG caches are redirected to
`/tmp/octop-cache`; they are not persistent application data.

`OCTOP_PERSISTENT_ROOT=/data` activates a revision-bound upstream patch that
rejects Agent host workspaces outside the mounted volume. The patch is inert
when that environment variable is unset, preserving upstream behavior outside
this HFS image.

Remote Desktop is disabled for this Hugging Face deployment. A revision-bound
source patch removes its backend router, dashboard route, and navigation item;
the image installs only the browser extra and fails the build or startup if an
`Xvnc`/`Xtigervnc` binary is present. Remote Browser through Playwright remains
available because it does not require the blocked VNC server process.

The login values are maintained in the ignored local `.env` ledger and
synchronized as the Space variable `OCTOP_ADMIN_USERNAME` and secret
`OCTOP_DEFAULT_PASSWORD`. They are not stored in Git or this README.

## HFS classification

```text
standard:       HFS v3.0
project_class:  preview
target_role:    primary
sovereignty:    port
lane:           source
version_source: commit
visibility:     protected Space / private bucket
```

`hfs-dev.toml` records the deployment target and standard-to-upstream
environment mapping. `config.toml` is the non-secret HFS operations contract
consumed by `scripts/verify_hfs_storage.py`; it records the expected bucket,
mount, paths, and backup policy but is not an upstream Octop configuration
file. Octop's live configuration remains the bucket-backed
`/data/.octop/config.json`. Both revision-bound patches are checked against the
immutable upstream commit before they are applied, so upstream drift fails the
build.

## Local build

The build downloads the pinned Octop source plus locked npm, Python, and
Playwright dependencies. It does not install them on the host.

```bash
docker build -t octop-all-in-one-hfs .
docker run --rm \
  -p 7860:7860 \
  -e OCTOP_DEFAULT_PASSWORD='<local-preview-password>' \
  -v octop-preview-data:/data \
  octop-all-in-one-hfs
```

Check the service after startup:

```bash
curl -fsS http://127.0.0.1:7860/api/health
```

Running the container without `-v ...:/data` is expected to fail the storage
preflight.

## Storage verification

Use the read-only audit script to compare the live Space, volume, and bucket:

```bash
python3 scripts/verify_hfs_storage.py
```

The script verifies the exact private bucket-to-`/data:rw` mapping and reports
top-level bucket usage without reading credentials, database rows, or object
contents. Persistent `.cache` data is reported as a warning because old cache
objects remain until they are reviewed and explicitly removed.

## Persistence boundary

The Space expects a private Hugging Face Storage Bucket mounted read-write at
`/data`. One bucket belongs to one writable Space instance; do not attach this
SQLite-backed data bucket read-write to another Space or replica. Agent host
workspaces must resolve under `/data`, while temporary files and caches belong
under `/tmp`.

Octop automatic backups are enabled daily at `04:00` with seven archives kept
under `/data/.octop/backups`. These provide application-level SQLite/workspace
recovery but do not protect against deleting the non-versioned primary bucket.
A separate private cold-backup bucket remains an operations decision and must
copy completed backup archives rather than the live `octop.db` file.

Changing, sharing, cleaning, or deleting the primary bucket is outside normal
preview deployment and requires a separate data/rollback decision. In
particular, browser profiles contain login state and must not be treated as
disposable cache. Redirect cache writes first, verify the new runtime, and only
then review old `.cache` objects with a dry run before any deletion.

## Licensing

The wrapper files in this repository are provided under GPL-3.0. The fetched
Octop source retains its upstream MIT license and notices.
