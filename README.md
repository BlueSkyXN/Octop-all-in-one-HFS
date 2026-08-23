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
- Hugging Face Space: <https://huggingface.co/spaces/BlueSkyXN/Octop-all-in-one-HFS>
- Live app: <https://blueskyxn-octop-all-in-one-hfs.hf.space>
- Space mode: Docker, protected preview, `cpu-basic`
- Public port: `7860`
- Persistent data: private bucket mounted at `/data`

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

/data/.octop
  |- SQLite database
  |- users and credentials
  |- agents, workspaces, chats, and settings
  `- runtime configuration
```

The wrapper requires `OCTOP_DEFAULT_PASSWORD`; it does not allow the upstream
well-known fallback password. On first start, the upstream idempotent container
entrypoint initializes `/data/.octop` and then starts `octop run` on port 7860.
Subsequent starts reuse the existing database.

The image also preinstalls the upstream Linux virtual desktop (TigerVNC on
`:99`, Openbox/XFCE) and starts it with the container. Hugging Face runs uid
`1000` without sudo, so the in-app "Install virtual desktop" button cannot
install packages or write `/opt` and `/etc`. After a rebuild, open Remote
Desktop directly; do not retry that installer. UI geometry change and
uninstall still need root/sudo and are not supported in this preview.

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

`hfs-dev.toml` records the deployment contract and the standard-to-upstream
environment mapping. `config.toml` records the non-secret preview defaults.

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

## Persistence boundary

The Space expects a private Hugging Face Storage Bucket mounted read-write at
`/data`. Without that mount, all Octop state is ephemeral and can be lost on a
rebuild, restart, or stop. Changing or deleting the bucket is outside normal
preview deployment and requires a separate data/rollback decision.

## Licensing

The wrapper files in this repository are provided under GPL-3.0. The fetched
Octop source retains its upstream MIT license and notices.
