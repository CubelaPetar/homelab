---
author: Petar Cubelaa
title: "TODOs in homelab infra"
description: "All relevant todos for homelab"
date-created: 2026-06-04
---

## TODO

- [x] home net: configure home network such that I have access from work (ds lite and work has no working ipv6) 
    - [x] Option 1.: setup s2s between home and vps and road warrior to vps from ipv4-only networks
    - [ ] (DISCARDED) Option 2.: setup netbird for access from everywhere or setup wireguard on my vps as vpn bridge
- [x] gpu server: debug problems
    - [x] wakeonlan does not work. nothing happens although configured on os and bios level
    - [x] nfs mounting via fstab not working. 'network not reachable'
- [x] pve-turtle: Backup my files to Hetzner storage share
    - [x] check remote backups succeded via both scripts
    - [x] delete old archive files
    - [x] clean /mnt/ssd/pve-* from not needed files
- [x] pve-turtle: check all my cronjob (backup) scripts and correct errors
- [x] llm: add traefik to llm stack
- [x] llm: proper ipv6 stack for docker 
- [ ] server: work out update strategy for servers and containers. Use renovate and scripts
- [ ] vps: Upgrade mailcow
- [ ] vps: check my git server for improvements
- [ ] home net: rebuild my wifi naming and visibility
- [ ] git: setup gitea runner?
- [ ] git: migrate to forgejo
- [ ] opnsense: migrate ipv6 config from 'track interface' to 'identity association'
- [ ] dns: migrate away from pihole
- [ ] caddy: fuse the caddy ansible roles into one 
