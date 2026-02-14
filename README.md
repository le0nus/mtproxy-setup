# mtproxy-setup

One-liner installer for [Telemt](https://github.com/telemt/telemt) — a fast Rust-based MTProto proxy for Telegram with Fake TLS support.

## Quick Start

```bash
curl -fsSL https://raw.githubusercontent.com/le0nus/mtproxy-setup/master/install.sh | sudo bash
```

The script will interactively ask for:
- **Port** (default: `443`)
- **TLS masking domain** (default: `api.vk.com`) — makes traffic look like regular HTTPS to this site
- **Metrics** — optional Prometheus endpoint on port 9090

After installation, you'll get a ready-to-use `tg://proxy?...` link.

## What it does

1. Checks that port 443 is free (offers to stop nginx/angie/apache if needed)
2. Installs Docker if not present (via [get.docker.com](https://get.docker.com))
3. Generates a random 32-byte secret
4. Creates config files in `/opt/telemt/`
5. Pulls and starts the [telemt-docker](https://hub.docker.com/r/whn0thacked/telemt-docker) container
6. Runs health checks
7. Outputs connection links with `ee`-prefixed secret (Fake TLS mode)

## Requirements

- Linux (Debian/Ubuntu/CentOS/Fedora)
- Root access
- Free port 443

## Secret format

The installer generates secrets in **EE-TLS** format:

```
ee<32-hex-secret><domain-in-hex>
```

For example, with domain `api.vk.com`:
```
ee90016bf9b326136641e186f21b2d14366170692e766b2e636f6d
^^                                ^^^^^^^^^^^^^^^^^^^^^^
ee prefix                         "api.vk.com" in hex
```

This tells Telegram clients to use Fake TLS obfuscation, making proxy traffic indistinguishable from regular HTTPS.

## Management

```bash
# View logs
docker compose -f /opt/telemt/docker-compose.yml logs -f

# Restart
docker compose -f /opt/telemt/docker-compose.yml restart

# Stop
docker compose -f /opt/telemt/docker-compose.yml down
```

## Config files

| File | Description |
|------|-------------|
| `/opt/telemt/telemt.toml` | Telemt configuration |
| `/opt/telemt/docker-compose.yml` | Docker Compose stack |
