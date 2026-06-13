# Homelab Infrastructure

Personal production infrastructure managed with Ansible. Covers a home server cluster, two VPS instances, and a Hetzner Storage Box — all wired together with WireGuard VPN and backed by a layered restic strategy.

---

## Architecture Overview

```
                         Internet
                            │
              ┌─────────────┴─────────────┐
              │                           │
      ┌───────▼──────┐          ┌─────────▼────────┐
      │  cloud VPS   │          │  petarcubela VPS  │
      │  (dual-stack)│          │  (mailcow + misc) │
      │  Traefik     │          │                   │
      │  Monitoring  │          └──────────┬─────────┘
      │  Static sites│                     │
      │  Nextcloud   │                     │
      │  SearXNG     │                     │
      └──────┬───────┘                     │
             │ WireGuard hub               │
             │ (site-to-site + road warrior)│
             │                             │
    ─ ─ ─ ─ ─▼─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┘
   │         Home LAN (DS-Lite / IPv6)         │
   │                                            │
   │  ┌────────────┐      ┌──────────────────┐  │
   │  │  OPNsense  │      │   pve-turtle     │  │
   │  │  Firewall  │      │  NAS + Proxmox   │  │
   │  │  DHCP/DNS  │      │  SnapRAID parity │  │
   │  │  WireGuard │      │  NFS/SMB exports │  │
   │  └────────────┘      └────────┬─────────┘  │
   │                               │ NFS         │
   │         ┌─────────────────────┼──────────┐  │
   │         │                     │          │  │
   │  ┌──────▼──┐  ┌──────────┐  ┌▼────────┐ │  │
   │  │ media VM│  │  ad VM   │  │llm host │ │  │
   │  │ immich  │  │  lldap   │  │ ollama  │ │  │
   │  │ paperless│  │authentik │  │open-webui│ │  │
   │  │ gitea   │  │          │  │SearXNG  │ │  │
   │  │ karakeep│  └──────────┘  │Immich AI│ │  │
   │  │ jellyfin│                │Paperless│ │  │
   │  └─────────┘                │  AI     │ │  │
   │                             └─────────┘ │  │
   └────────────────────────────────────────────┘
```

---

## Nodes

### Home

| Host | Role | OS | Notes |
|---|---|---|---|
| `opnsense` | Firewall, gateway, DHCP, DNS | OPNsense | DS-Lite WAN — public IPv6 only, no native IPv4 |
| `pve-turtle` | NAS + Proxmox hypervisor | Proxmox VE | 1 TB SSD + 4 TB data disk + 4 TB parity (SnapRAID) |
| `media` VM (VMID 102) | Media and productivity services | Debian | NFS-mounted appdata and media from turtle |
| `ad` VM | Identity management | Debian | lldap (LDAP) + Authentik (OIDC/SSO) |
| `llm` host | GPU inference server | Debian (bare metal) | NVIDIA GPU; auto-shutdown 23:00 daily |
| `jc_pve` | Secondary Proxmox (friend's homelab) | Proxmox VE | Reached via WireGuard; SnapRAID storage |

### Cloud

| Host | Role | Notes |
|---|---|---|
| `cloud` VPS | Public-facing services | Dual-stack; WireGuard VPN hub |
| `petarcubela` VPS | Mail server + personal sites | Mailcow; backs up directly to Hetzner Storage Box |

---

## Home Network

- **WAN:** DS-Lite — native IPv6 only, no public IPv4. IPv4 internet access via CGNAT carrier tunnel.
- **Firewall/router:** OPNsense
- **IPv4 LAN:** `10.56.0.0/20`
- **IPv6 ULA block:** `fde4:ed21:b2c0:5600::/56` (covers all VLANs)
- **DNS/DHCP:** Pi-hole (primary) + Unbound
- **Domain:** `reliyya.xyz` (internal services) / `petarcubela.de` / `scienceqorner.com`

### VLANs (abbreviated)

| VLAN | Subnet | Purpose |
|---|---|---|
| MGMT | `10.56.0.0/24` | Infrastructure management |
| SERVER | `10.56.1.0/24` | Servers and VMs |
| DMZ | `10.56.6.0/24` | Public-facing ingress |

---

## Services

### media VM

| Service | URL | Purpose |
|---|---|---|
| Immich | `immich.reliyya.xyz` | Photo management |
| Paperless-ngx | `paperless.reliyya.xyz` | Document management |
| Gitea | `git.reliyya.xyz` | Self-hosted Git |
| Karakeep | `karakeep.reliyya.xyz` | Bookmark manager |
| Jellyfin | `jellyfin.reliyya.xyz` | Media streaming |

### llm host

| Service | Purpose |
|---|---|
| Ollama | Local LLM inference (NVIDIA GPU) |
| Open WebUI | LLM chat interface |
| SearXNG | Private search |
| Immich AI | Machine learning for Immich |
| Paperless AI | OCR/classification AI for Paperless |

### ad VM (Identity)

| Service | Purpose |
|---|---|
| lldap | Lightweight LDAP directory |
| Authentik | SSO / OIDC provider |

### cloud VPS

| Service | Purpose |
|---|---|
| Traefik | Reverse proxy + TLS termination |
| Beszel agent | Monitoring |
| Nextcloud | Cloud storage (`nc.scienceqorner.com`) |
| SearXNG | Public search instance |
| Static sites | Personal and project sites |

### pve-turtle

- **SnapRAID** — parity protection for `disk1` (4 TB data, 4 TB parity)
- **NFS exports** — serves `appdata/` and `media/` to the media VM and llm host over IPv6
- **SMB shares** — `projects`, `ISOs`, `paperless_consume` (ingestion inbox)

---

## VPN Architecture

The home network runs on DS-Lite (IPv6 only, no public IPv4). To reach home services from IPv4-only locations (corporate networks, travel), a WireGuard hub-and-spoke topology is used with the dual-stack cloud VPS as the hub.

```
[Home LAN 10.56.0.0/20 + fde4:ed21:b2c0:5600::/56]     [Work / Road Warrior]
        │                                                         │
  [OPNsense — WireGuard peer]                        WireGuard client
   10.0.0.2/24                                        10.0.0.3/24
   fde4:ed21:b2c0:56dd::2/64                     fde4:ed21:b2c0:56dd::3/64
        │                                                         │
        └──── IPv6 tunnel ──── [cloud VPS] ──── IPv4 tunnel ─────┘
                              10.0.0.1/24
                        fde4:ed21:b2c0:56dd::1/64
                              WireGuard Hub
                           Port 51822/UDP
```

### Tunnel addressing

| Role | WireGuard IPv4 | WireGuard IPv6 (ULA) |
|---|---|---|
| Hub (cloud VPS) | `10.0.0.1/24` | `fde4:ed21:b2c0:56dd::1/64` |
| Home gateway (OPNsense) | `10.0.0.2/24` | `fde4:ed21:b2c0:56dd::2/64` |
| Road warrior (work/laptop) | `10.0.0.3/24` | `fde4:ed21:b2c0:56dd::3/64` |

- **Tunnel subnet:** `10.0.0.0/24` / `fde4:ed21:b2c0:56dd::/64`
- **Home→VPS leg:** travels over native IPv6 (bypasses DS-Lite CGNAT)
- **Work→VPS leg:** travels over IPv4 (VPS is dual-stack, accepts both)
- **Dynamic home IP:** OPNsense pushes a DDNS update to `vpn.reliyya.xyz` (AAAA record) on every IPv6 change; the VPS learns the home peer address dynamically when OPNsense initiates

### What the work machine can reach through the tunnel

- All home LAN devices by IPv4 (`10.56.0.0/20`)
- All home devices that have only a ULA IPv6 address (`fde4:ed21:b2c0:5600::/56`)
- Internet traffic from work stays local (split tunnel)

Full setup instructions: [`docs/vpn_infra/s2s-home-vps-road_warrior.md`](docs/vpn_infra/s2s-home-vps-road_warrior.md)

---

## Backup Strategy

### Design goals

- **Appdata consistency:** databases (Postgres, MariaDB, SQLite) are active 24/7 via NFS. The media VM is cleanly shut down before each backup window so all database files are cold and safe to copy — no `pg_dump` or cross-VM SSH tricks needed.
- **Two-tier storage:** a local restic repo on turtle's `disk1` (SnapRAID-protected) plus an offsite copy on a Hetzner Storage Box.
- **Hetzner path uses IPv6:** the home→Hetzner connection is forced to IPv6 to bypass DS-Lite CGNAT, which resets long TCP sessions mid-upload.
- **PVE dumps stay local:** vzdump `.vma.zst` files are pre-compressed; restic cannot deduplicate them, so uploading them offsite would consume the entire storage quota without meaningful benefit.

### Backup schedule (daily on turtle)

```
02:00  pve-host-backup.sh   — PVE host config → /mnt/ssd/pve-turtle/host-config
       backup-appdata.sh    — shuts down media VM (VMID 102), restic appdata/, restarts VM
                              (runs in parallel with pve-host-backup.sh — different paths)

02:30  backup-restic.sh     — restic backup of projects/ + pve-*/
                            — copies appdata + projects snapshots to Hetzner
                            — prunes both local and remote repos

Sunday 04:00
       backup-media-weekly.sh — restic backup of disk1/media/ (VM stays up — plain files, no DB)
                              — copies media snapshots to Hetzner
```

### What is backed up

| Source | Local repo | Hetzner | Schedule |
|---|---|---|---|
| PVE host config (tar.gz) | ✓ | ✓ (via restic) | Daily 02:00 |
| `/mnt/ssd/appdata/` | ✓ | ✓ | Daily 02:00 |
| `/mnt/ssd/projects/` | ✓ | ✓ | Daily 02:30 |
| `/mnt/ssd/pve-*/dump/` | ✓ | ✗ local only | Daily 02:30 |
| `/mnt/disk1/media/` | ✓ | ✓ | Weekly Sunday 04:00 |

### Retention

| Data | Local | Hetzner |
|---|---|---|
| appdata | 7 daily, 4 weekly, 6 monthly | 7 daily, 4 weekly, 12 monthly |
| projects | 7 daily, 4 weekly, 6 monthly | 7 daily, 4 weekly, 12 monthly |
| pve dumps + host configs | 7 daily, 4 weekly, 6 monthly | local only |
| media | 8 weekly, 12 monthly | 4 weekly, 6 monthly |

### Intentional exclusions

| Path | Reason |
|---|---|
| `appdata/apps/ollama/models/` | Re-downloadable; large |
| `appdata/apps/jellyfin/cache/` | Regenerated on startup |
| `appdata/apps/open-webui/cache/` | Regenerated on startup |
| `appdata/apps/paperless_data/index/` | Whoosh index; rebuilt from DB |
| `disk1/media/downloads/` | Transient staging area |
| PVE dumps (Hetzner) | Pre-compressed, no dedup benefit; local copy sufficient |

### Offsite storage

Hetzner Storage Box (BX11, 1 TB) — connected via SFTP over IPv6.  
Backup logs: `/var/log/turtle-backup.log`

Full strategy and scripts: [`docs/backup_strategy/20260612-turtle-backup-strategy-offsite_v3.md`](docs/backup_strategy/20260612-turtle-backup-strategy-offsite_v3.md)

---

## Ansible Structure

```
.
├── hosts.ini                  # Inventory
├── group_vars/                # Per-group variables (secrets in secrets.yml, vault-encrypted)
├── roles/                     # Custom roles (autorestic, caddy, dhcp-dns, snapraid, …)
├── services/                  # Docker Compose stacks, one folder per host group
│   ├── media/                 # immich, paperless, gitea, karakeep, jellyfin
│   ├── llm/                   # ollama, open-webui, searxng, immich-ai, paperless-ai
│   ├── ad/                    # lldap, authentik
│   ├── cloud/                 # traefik, monitoring, static sites, nextcloud
│   └── jc_pve/                # Secondary homelab services
├── playbooks/                 # update.yml, shutdown.yml, pve-updates.yml
├── run.yml                    # Main playbook
└── justfile                   # Common task shortcuts
```

Compose stacks are generated from Jinja2 templates via the `ironicbadger.docker_compose_generator` role and deployed by Ansible. Each stack lives in a numbered subdirectory (e.g. `01-traefik`, `02-ai`) — lower numbers start first.

---

## Tooling

| Tool | Purpose |
|---|---|
| Ansible | Configuration management and deployment |
| Proxmox VE | Type-1 hypervisor for home VMs |
| Docker / Compose | Container runtime on all VMs |
| Traefik | Reverse proxy with automatic TLS (Let's Encrypt) |
| OPNsense | Firewall, DHCP, WireGuard |
| WireGuard | Site-to-site VPN and road warrior access |
| restic | Incremental encrypted backups |
| SnapRAID | Parity protection for spinning disks |
| Pi-hole | DNS filtering and local DNS |
| lldap + Authentik | LDAP directory + SSO/OIDC |
| Beszel | Lightweight server monitoring |
