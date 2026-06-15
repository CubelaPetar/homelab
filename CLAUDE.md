# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Common Commands

All shortcuts are in the `justfile` (run with `just`):

```bash
just run <HOST> [TAGS]        # Run the main playbook against a specific host
just compose <HOST>           # Deploy only Docker Compose stacks to a host
just reqs [--force]           # Install Ansible Galaxy roles from requirements.yml
just vault <encrypt|decrypt|edit>  # Manage secrets.yml via ansible-vault (opens nvim)
```

Direct Ansible equivalents:

```bash
ansible-playbook -b run.yml --limit media          # Full run against media VM
ansible-playbook run.yml --limit media --tags compose  # Compose stacks only
ansible-playbook playbooks/update.yml              # Dist-upgrade all hosts
ansible-playbook playbooks/shutdown.yml            # Graceful shutdown
ansible-vault edit group_vars/secrets.yml          # Edit encrypted secrets
ansible-galaxy install -r requirements.yml         # Install galaxy roles
```

## Architecture

### How services are deployed

Docker Compose stacks are **generated from Jinja2 templates** using the `ironicbadger.docker_compose_generator` Galaxy role. The source definitions live in `services/<host_group>/` as numbered subdirectories (e.g. `01-traefik`, `02-jellyfin`). Ansible renders them into `~/docker/` on the target host and runs `docker compose up -d`. Lower numbers start first — order matters for network/dependency reasons.

The `run.yml` playbook is the single entrypoint for all hosts. Each play targets a host group, loads `group_vars/secrets.yml`, and applies roles. The `compose` tag is the fast path to redeploy stacks without running the full role chain.

### Secrets

All secrets are in `group_vars/secrets.yml`, encrypted with `ansible-vault`. The vault password must be available (file or env var) for any playbook run that loads secrets. Do not add plaintext secrets anywhere else.

### Variables layering

- `group_vars/all.yml` — global defaults (`main_username`, `docker_dir`, NTP timezone, base domains)
- `group_vars/<group>.yml` — per-host-group overrides (paths, NFS mounts, service-specific vars)
- `group_vars/secrets.yml` — vault-encrypted credentials, tokens, passwords

Key globals: `main_username=reliyya`, `main_uid=1000`, `docker_dir=/home/reliyya/docker`, `domain_base=reliyya.xyz`.

### Inventory structure

`hosts.ini` defines all hosts. Notable groups:
- `homelab` — all home nodes (turtle + turtleskids + llm)
- `turtleskids` — VMs and services running on pve-turtle (media, ad, caddy, pihole, etc.)
- `vps` — cloud VPS and petarcubela VPS (SSH port 69, user `petar`)
- `homelab` group uses SSH port 2222, user `reliyya` by default

### NFS dependency

The `media` and `llm` hosts mount `/mnt/nfs/appdata` and `/mnt/nfs/media` from `nas.reliyya.xyz` (pve-turtle) over NFS. The `nfs-client` role manages `/etc/fstab` entries. Service containers expect these mounts to exist before starting — the `_netdev` mount option ensures NFS waits for the network.

### Custom roles

Local roles in `roles/` (not from Galaxy):
- `caddy` / `caddy_srv` / `caddy_dmz` — Caddy reverse proxy for different network zones (LAN, server VLAN, DMZ)
- `dhcp-dns` — Pi-hole DHCP/DNS configuration
- `disks` / `snapraid` — disk setup and SnapRAID parity config for turtle and jc_pve
- `nfs-client` — NFS mount management via fstab
- `packages` — base package installs
- `samba` — SMB share configuration
- `smtp` — mail relay
- `autorestic` — restic backup wrapper (currently commented out in run.yml)

### Scripts submodule

`scripts/` is a git submodule pointing to `https://git.reliyya.xyz/petar.cubela/scripts.git`. After cloning, run `git submodule update --init` to populate it.
