# WireGuard Site-to-Site VPN Manual

## Home (DS-Lite/IPv6) ↔ VPS (Dual-Stack) ↔ Work (IPv4)

---

## Overview

This setup bridges a DS-Lite home network (IPv6 only, no public IPv4) with an IPv4-only workplace network, using a dual-stack VPS as a WireGuard hub. The tunnel carries both IPv4 (`10.0.0.0/24`) and IPv6 ULA (`fde4:ed21:b2c0:56dd::/64`) so that home devices with only a ULA IPv6 address are reachable from work.

```
[Home LAN 10.56.0.0/20 + fde4:ed21:b2c0:5600::/56]     [Work Machine]
        |                                                       |
  [OPNsense Firewall]                                  WireGuard client
   WireGuard peer                                       10.0.0.3/24
   10.0.0.2/24                                    fde4:ed21:b2c0:56dd::3/64
   fde4:ed21:b2c0:56dd::2/64                               |
        |                                                   |
        └──── IPv6 tunnel ──────[VPS]────── IPv4 tunnel ───┘
                          10.0.0.1/24
                    fde4:ed21:b2c0:56dd::1/64
                         WireGuard Hub
```

---

## Network Plan

|Role|Device|WireGuard IPv4|WireGuard IPv6 (ULA)|Public Endpoint|
|---|---|---|---|---|
|**Hub**|VPS|`10.0.0.1/24`|`fde4:ed21:b2c0:56dd::1/64`|`VPS_PUBLIC_IPv4_REDACTED` (IPv4) / `VPS_PUBLIC_IPv6_REDACTED` (IPv6)|
|**Home gateway**|OPNsense|`10.0.0.2/24`|`fde4:ed21:b2c0:56dd::2/64`|`vpn.reliyya.xyz` (dynamic IPv6 via DDNS)|
|**Work machine**|Laptop/PC|`10.0.0.3/24`|`fde4:ed21:b2c0:56dd::3/64`|`WORK_PUBLIC_IPv4_REDACTED` (IPv4)|

- **Home LAN IPv4 subnet:** `10.56.0.0/20`
- **Home LAN IPv6 ULA block:** `fde4:ed21:b2c0:5600::/56` (covers all home VLANs)
- **WireGuard tunnel IPv4 subnet:** `10.0.0.0/24`
- **WireGuard tunnel IPv6 subnet:** `fde4:ed21:b2c0:56dd::/64`
- **WireGuard port:** `51822/udp`

> **Subnet allocation note:** `56dd::/64` was chosen for the tunnel to keep `5611::/64` and nearby subnets free for future VLAN expansion. The `/56` summary `fde4:ed21:b2c0:5600::/56` covers all home ULA VLANs (`5600`–`56ff`) in a single route advertisement.

---

## Part 1 — VPS Setup

### 1.1 Generate Keys

```bash
wg genkey | tee /etc/wireguard/vps_private.key | wg pubkey > /etc/wireguard/vps_public.key
chmod 600 /etc/wireguard/vps_private.key
```

### 1.2 Enable IP Forwarding

```bash
cat >> /etc/sysctl.conf << 'EOF'
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
EOF
sysctl -p
```

### 1.3 WireGuard Config `/etc/wireguard/wg0.conf`

```ini
[Interface]
Address    = 10.0.0.1/24, fde4:ed21:b2c0:56dd::1/64
ListenPort = 51822
PrivateKey = <vps-private-key>

# Forward between peers (IPv4 + IPv6); masquerade IPv4 outbound only
# Replace eth0 with your actual interface (check with: ip -br link)
PostUp   = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -A FORWARD -o wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE; ip6tables -A FORWARD -i wg0 -j ACCEPT; ip6tables -A FORWARD -o wg0 -j ACCEPT
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -D FORWARD -o wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE; ip6tables -D FORWARD -i wg0 -j ACCEPT; ip6tables -D FORWARD -o wg0 -j ACCEPT

# ── Home (OPNsense) ───────────────────────────────────────────
[Peer]
PublicKey  = <opnsense-public-key>
# No Endpoint — OPNsense initiates, VPS learns the address dynamically
# AllowedIPs: tunnel IPs + entire home IPv4 LAN + entire home ULA /56 block
AllowedIPs = 10.0.0.2/32, fde4:ed21:b2c0:56dd::2/128, 10.56.0.0/20, fde4:ed21:b2c0:5600::/56

# ── Work machine ──────────────────────────────────────────────
[Peer]
PublicKey  = <work-public-key>
AllowedIPs = 10.0.0.3/32, fde4:ed21:b2c0:56dd::3/128
# No Endpoint needed — work machine initiates the connection
```

> **Note:** `PostUp`/`PostDown` must be on a single unbroken line each. The `wg-quick` parser does not support backslash line continuations.

### 1.4 Enable and Start

```bash
systemctl enable --now wg-quick@wg0
wg show   # verify interface and peers
```

### 1.5 UFW Firewall

```bash
# Allow WireGuard port
ufw allow 51822/udp comment "WireGuard"

# Allow forwarding between peers
# In /etc/default/ufw, ensure:
DEFAULT_FORWARD_POLICY="ACCEPT"

ufw reload
```

---

## Part 2 — OPNsense (Home Gateway)

All steps performed in the OPNsense web UI.

### 2.1 Create WireGuard Instance

**VPN → WireGuard → Local → Add**

|Field|Value|
|---|---|
|Name|`wgvpstunnel`|
|Listen Port|`51822`|
|Tunnel Address|`10.0.0.2/24`, `fde4:ed21:b2c0:56dd::2/64`|
|Generate keypair|✅ — copy the public key for use on the VPS|

### 2.2 Add VPS as a Peer

**VPN → WireGuard → Peers → Add**

|Field|Value|
|---|---|
|Name|`vps-hub`|
|Public Key|`<vps-public-key>`|
|Endpoint Address|`VPS_PUBLIC_IPv6_REDACTED`|
|Endpoint Port|`51822`|
|Allowed IPs|`10.0.0.0/24`, `fde4:ed21:b2c0:56dd::/64`|
|Keepalive|`25`|

> Use the VPS **IPv6 address** as the endpoint — the home→VPS leg travels over IPv6 since home has no public IPv4.

### 2.3 Assign the WireGuard Interface

**Interfaces → Assignments** → assign the new `wg` interface, enable it.

### 2.4 Add Gateway

**System → Gateways → Configuration → Add**

|Field|Value|
|---|---|
|Name|`wg-vps-tunnel_gw`|
|Interface|`wgvpstunnel`|
|Address Family|`IPv4`|
|IP Address|`10.0.0.1`|
|Description|`WireGuard interface gateway`|

> **Important:** OPNsense does not automatically create a connected route for WireGuard interfaces the way Linux does natively. The gateway object must be created manually.

### 2.5 Add Static Route

**System → Routes → Configuration → Add**

|Field|Value|
|---|---|
|Network Address|`10.0.0.0/24`|
|Gateway|`wg-vps-tunnel_gw - 10.0.0.1`|
|Description|`WireGuard interface gateway`|

> This route is required. Without it OPNsense does not know to send return traffic for `10.0.0.0/24` back into the tunnel.

### 2.6 Add IPv6 Gateway

**System → Gateways → Configuration → Add**

|Field|Value|
|---|---|
|Name|`wg-vps-tunnel_gw6`|
|Interface|`wgvpstunnel`|
|Address Family|`IPv6`|
|IP Address|`fde4:ed21:b2c0:56dd::1`|
|Description|`WireGuard VPS tunnel IPv6 gateway`|

### 2.7 Add IPv6 Static Route

**System → Routes → Configuration → Add**

|Field|Value|
|---|---|
|Network Address|`fde4:ed21:b2c0:56dd::/64`|
|Gateway|`wg-vps-tunnel_gw6 - fde4:ed21:b2c0:56dd::1`|
|Description|`WireGuard VPS tunnel IPv6 route`|

### 2.8 Firewall Rules

**Firewall → Rules → [wgvpstunnel interface] → Add** (IPv4 — allow tunnel subnet)

|Field|Value|
|---|---|
|Action|Pass|
|TCP/IP Version|IPv4|
|Source|`10.0.0.0/24`|
|Destination|`10.0.0.0/24`|

> OPNsense blocks all traffic on new interfaces by default. This rule allows the VPS to reach the OPNsense tunnel IP and enables ICMP (ping) to work across the tunnel.

**Firewall → Rules → [wgvpstunnel interface] → Add** (IPv4 — allow access to home LAN)

|Field|Value|
|---|---|
|Action|Pass|
|TCP/IP Version|IPv4|
|Source|`10.0.0.0/24`|
|Destination|`10.56.0.0/20`|

**Firewall → Rules → [wgvpstunnel interface] → Add** (IPv6 — allow access to home ULA)

|Field|Value|
|---|---|
|Action|Pass|
|TCP/IP Version|IPv6|
|Source|`fde4:ed21:b2c0:56dd::/64`|
|Destination|`fde4:ed21:b2c0:5600::/56`|

**Firewall → Rules → LAN → Add**

|Field|Value|
|---|---|
|Action|Pass|
|TCP/IP Version|IPv4+IPv6|
|Source|`10.56.0.0/20` / `fde4:ed21:b2c0:5600::/56`|
|Destination|`10.0.0.0/24` / `fde4:ed21:b2c0:56dd::/64`|

---

## Part 3 — Work Machine

### 3.1 Generate Keys

**Linux/macOS:**

```bash
wg genkey | tee work_private.key | wg pubkey > work_public.key
```

**Windows:** Use the official WireGuard GUI — it generates the keypair automatically.

### 3.2 WireGuard Config `work.conf`

```ini
[Interface]
Address    = 10.0.0.3/24, fde4:ed21:b2c0:56dd::3/64
PrivateKey = <work-private-key>
DNS        = 10.56.0.1, fde4:ed21:b2c0:5600::254   # OPNsense MGMT (IPv4 + IPv6)

[Peer]
PublicKey           = <vps-public-key>
Endpoint            = VPS_PUBLIC_IPv4_REDACTED:51822   # VPS IPv4 address
AllowedIPs          = 10.0.0.0/24, 10.56.0.0/20, fde4:ed21:b2c0:56dd::/64, fde4:ed21:b2c0:5600::/56
PersistentKeepalive = 25
```

`AllowedIPs` routes tunnel traffic, the entire home IPv4 LAN, the tunnel IPv6 subnet, and the entire home ULA `/56` block through the VPS. Internet traffic from work remains local.

### 3.3 Add Work Machine Peer to VPS

Once you have the work machine's public key, add it to the VPS:

```bash
# Add live without dropping existing connections
wg set wg0 peer <work-public-key> allowed-ips 10.0.0.3/32,fde4:ed21:b2c0:56dd::3/128

# Persist to config
wg-quick save wg0
```

---

## Verification

### On the VPS

```bash
# Check tunnel status and peer handshakes
wg show

# Healthy output shows recent handshake and data transfer:
# peer: <opnsense-pubkey>
#   latest handshake: 14 seconds ago
#   transfer: 1.23 MiB received, 456 KiB sent

# Ping OPNsense tunnel IPs
ping 10.0.0.2
ping6 fde4:ed21:b2c0:56dd::2

# Ping a home LAN device (IPv4 + IPv6 ULA)
ping 10.56.0.1
ping6 fde4:ed21:b2c0:5600::254

# Ping work machine tunnel IPs (once work peer is connected)
ping 10.0.0.3
ping6 fde4:ed21:b2c0:56dd::3
```

### From Work Machine

```bash
# Ping VPS tunnel IPs
ping 10.0.0.1
ping6 fde4:ed21:b2c0:56dd::1

# Ping OPNsense tunnel IPs
ping 10.0.0.2
ping6 fde4:ed21:b2c0:56dd::2

# Ping a home LAN device by IPv4
ping 10.56.0.1

# Ping a home device that only has a ULA IPv6 address
ping6 fde4:ed21:b2c0:5601::something   # e.g. SERVER VLAN device
```

### Packet-level debugging (on VPS)

```bash
# Watch ICMP traffic on the tunnel interface
tcpdump -i wg0 icmp

# If you see echo request but no echo reply:
# → packet reaches the tunnel but OPNsense is dropping it (check firewall rules)
# If you see nothing:
# → packet never enters the tunnel (check AllowedIPs and routing)
```

---

## Key Lessons Learned

- **`PostUp`/`PostDown` must be single lines** — `wg-quick` does not support backslash line continuations. All iptables commands must be semicolon-separated on one line.
    
- **IPv6 forwarding requires `ip6tables` rules** — the `PostUp`/`PostDown` rules need both `iptables` (IPv4) and `ip6tables` (IPv6) FORWARD rules. No IPv6 MASQUERADE is needed since ULA addresses are routed end-to-end.
    
- **Use a `/56` summary for home ULA in AllowedIPs** — `fde4:ed21:b2c0:5600::/56` covers all home VLANs (`5600`–`56ff`) in a single entry rather than listing each `/64` individually. Choose the tunnel subnet (`56dd`) outside this block to avoid overlap.
    
- **OPNsense requires an explicit gateway object** for WireGuard interfaces — unlike native Linux, it does not automatically install a connected route when the tunnel address is assigned. Required for both IPv4 and IPv6.
    
- **The static route for `10.0.0.0/24` is required** — without it OPNsense has no return path for tunnel subnet traffic.
    
- **A firewall rule on the WireGuard interface is required** — OPNsense blocks all inbound traffic on new interfaces by default, including ICMP from the VPS. The official WireGuard documentation does not clearly state this.
    
- **Dynamic home IPv6 is handled by DDNS + initiation direction** — the VPS does not need a static endpoint for the OPNsense peer; it learns it dynamically when OPNsense initiates the connection. `vpn.reliyya.xyz` keeps the AAAA record current via DDNS.
    
- **MTU** — if large transfers hang or TCP connections stall, add `MTU = 1420` to the `[Interface]` block of each WireGuard config.
    

---

## Troubleshooting Quick Reference

|Symptom|Likely cause|Fix|
|---|---|---|
|`wg-quick` fails to start|`PostUp` line continuation backslashes|Put all iptables commands on one line|
|Peer shows no handshake|Wrong endpoint IP/port, firewall blocking UDP 51822|Check `ufw status`, verify endpoint address|
|Ping to `10.0.0.2` hangs|OPNsense firewall blocking ICMP on wg interface|Add pass rule for `10.0.0.0/24` on wg interface|
|Can reach tunnel IPs but not home LAN|Missing static route or gateway on OPNsense|Add gateway `10.0.0.1` and route `10.0.0.0/24`|
|IPv4 works but ULA IPv6 unreachable|Missing `ip6tables` FORWARD rules on VPS|Add `ip6tables -A FORWARD` rules to `PostUp`|
|IPv6 ULA unreachable from work|Missing IPv6 gateway/route on OPNsense, or missing AllowedIPs entry|Add `wg-vps-tunnel_gw6` gateway, `56dd::/64` route, and ensure AllowedIPs includes `5600::/56`|
|Large transfers fail|MTU overhead|Add `MTU = 1420` to all `[Interface]` blocks|
|Home peer drops after IPv6 change|DDNS not updating fast enough|Check ddclient/DDNS updater logs; reduce TTL on DNS record|