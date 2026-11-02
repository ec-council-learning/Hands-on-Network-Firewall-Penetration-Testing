# Lab Layout & Setup — Hands-On Network Firewall Penetration Testing

Companion to `setup-lab.sh`. Build once, reuse for every recording session and every viewer running the course themselves.

---

## 1. Network Diagram

```
                          ┌──────────────────────────────────┐
                          │         HOST MACHINE             │
                          │   (VirtualBox / VMware Fusion)   │
                          └──────────────────────────────────┘
                                          │
        ┌─────────────────────────────────┴────────────────────────────────┐
        │                                                                  │
        │  vboxnet0  /  Host-Only Network — "WAN-side / external"          │
        │  192.168.100.0/24                                                │
        │                                                                  │
        │   ┌──────────────────┐                                           │
        │   │   KALI ATTACKER  │  eth0: 192.168.100.50/24                  │
        │   │   192.168.100.50 │  Default GW: 192.168.100.1 (pfSense WAN)  │
        │   └────────┬─────────┘                                           │
        │            │                                                     │
        │   ┌────────▼─────────────────────────────┐                       │
        │   │             pfSense VM (FW)          │   hop 1               │
        │   │   WAN: em0 → 192.168.100.1/24        │                       │
        │   │   LAN: em1 → 192.168.66.1/24         │                       │
        │   │   7 explicit WAN rules — see §6      │                       │
        │   │   Static route 56.0/24 via 66.2 (R2) │                       │
        │   │   Outbound NAT: DISABLED (pure route)│                       │
        │   └────────┬─────────────────────────────┘                       │
        │            │                                                     │
        │  vboxnet1  /  Host-Only Network — "DMZ transit"                  │
        │  192.168.66.0/24                                                 │
        │            │                                                     │
        │   ┌────────▼─────────────────────────────┐                       │
        │   │        R2 INTERNAL ROUTER            │   hop 2               │
        │   │   Alpine Linux 3.20 (router only)    │                       │
        │   │   eth0 (outer): 192.168.66.2/24      │                       │
        │   │   eth1 (inner): 192.168.56.1/24      │                       │
        │   │   net.ipv4.ip_forward = 1            │                       │
        │   │   Default GW: 192.168.66.1 (pfSense) │                       │
        │   │   NO filtering — pure forwarder      │                       │
        │   └────────┬─────────────────────────────┘                       │
        │            │                                                     │
        │  vboxnet2  /  Host-Only Network — "internal / behind R2"         │
        │  192.168.56.0/24                                                 │
        │            │                                                     │
        │   ┌────────▼─────────────────────────────┐   hop 3               │
        │   │   VICTIM (Ubuntu Server 24.04)       │                       │
        │   │   enp0s3 → 192.168.56.20/24          │                       │
        │   │   Default GW: 192.168.56.1 (R2)      │                       │
        │   │   nginx :80 / python http :8080      │                       │
        │   │   sshd :22 — no service on :443      │                       │
        │   └──────────────────────────────────────┘                       │
        └──────────────────────────────────────────────────────────────────┘

   PATH FROM ATTACKER TO VICTIM  = 3 hops (Kali → pfSense → R2 → victim)
   ON-CAMERA TARGET FOR NMAP     = victim Ubuntu 192.168.56.20
   FIREWALL RULES PROTECT        = victim services (HTTP/SSH/HTTPS)
   PENTEST POSTURE               = external attacker, NO admin access behind firewall
   FIREWALKING ORACLE            = R2 returns ICMP Time Exceeded for probes
                                   that pfSense forwarded — classical firewalk works
```

> **Why three networks and four VMs?** Classical firewalking needs a router *past* the filtering device. With only one hop past the firewall, the technique degrades to "any-response-vs-no-response" — the Nmap NSE `firewalk` script silently emits nothing. R2 restores the proper multi-hop topology and lets Nmap's firewalk script behave correctly.

> **Why outbound NAT disabled on pfSense?** With auto-NAT on, R2's ICMP Time Exceeded packets (sourced from `192.168.66.2`) would be SNAT'd to pfSense's WAN IP. Kali would see hop 1 = `192.168.100.1` (pfSense) and hop 2 = `192.168.100.1` again — firewalking signal collapses. Disable outbound NAT so source IPs are preserved end to end. (This is safe because the lab has no internet connection.)

---

## 2. VM Inventory

| VM | OS | vCPU | RAM | Disk | NICs |
|---|---|---|---|---|---|
| **Kali** (attacker) | Kali Linux 2026.x | 2 | 4 GB | 40 GB | 1× host-only `vboxnet0` (WAN) |
| **pfSense** (firewall) | pfSense CE 2.7.x | 2 | 2 GB | 20 GB | 2× host-only — `vboxnet0` (WAN), `vboxnet1` (DMZ) |
| **R2** (internal router) | Alpine Linux 3.20 | 1 | 256 MB | 2 GB | 2× host-only — `vboxnet1` (outer), `vboxnet2` (inner) |
| **Victim** (target) | Ubuntu Server 24.04 LTS | 1 | 2 GB | 20 GB | 1× host-only `vboxnet2` (internal) |

Total: ~6 vCPU, ~8.25 GB RAM, ~82 GB disk. Comfortable on 16 GB host; recommended 32 GB host for smooth recording.

---

## 3. Hypervisor Networks (VirtualBox example)

VirtualBox → File → Host Network Manager → **Create**:

| Adapter | IPv4 | Mask | DHCP |
|---|---|---|---|
| `vboxnet0` (WAN/external) | 192.168.100.1 | 255.255.255.0 | **disabled** |
| `vboxnet1` (DMZ transit) | 192.168.66.1 | 255.255.255.0 | **disabled** |
| `vboxnet2` (internal) | 192.168.56.1 | 255.255.255.0 | **disabled** |

DHCP off everywhere; static IPs throughout for repeatability across recordings.

> **VMware Fusion / Workstation:** create three **Custom (vmnet)** networks, host-only, DHCP off, same subnets.

---

## 4. pfSense Install

### 4.1 Install media

Download: `https://www.pfsense.org/download/` → AMD64 / DVD ISO installer.

### 4.2 VM creation

- Type: BSD / FreeBSD (64-bit)
- 2 vCPU, 2 GB RAM, 20 GB disk
- **Network adapter 1**: Host-only → `vboxnet0`  (becomes pfSense WAN, `em0`)
- **Network adapter 2**: Host-only → `vboxnet1`  (becomes pfSense LAN, `em1`)
- Promiscuous mode: **Allow All** on adapter 2 (needed for ARP/MiTM demos)

### 4.3 First boot interface assignment

Console menu after install:

```
2) Set interface(s) IP address
```

Press **2 → WAN**:
- DHCP? **n**
- IPv4: `192.168.100.1`
- Bit count: `24`
- Upstream gateway: *(blank)*
- IPv6: **n**

Press **2 → LAN**:
- IPv4: `192.168.66.1`
- Bit count: `24`
- DHCP server on LAN: **n**  (R2 has a static IP; no DHCP needed in transit segment)

### 4.4 Web UI access

From **Kali** (192.168.100.50): browse to `http://192.168.100.1`. Login: `admin / pfsense`. Wizard: Next-Next-Finish. Change admin password.

> **Gotcha (DNS rebind + HTTP_REFERER protection — first WAN-side login).** On a fresh pfSense build, the first WAN-side login will *succeed in the backend* (you can see `Successful login for user 'admin' from: 192.168.100.50` in the pfSense console / Status → System Logs) but the browser bounces back to the login page. The Web Configurator rejects the follow-up requests because the `Host:` header is a raw IP and the anti-rebind / referer checks fire. `pfctl -d` does NOT help — those checks live in the PHP layer, not in pf.
>
> **`pfSsh.php playback enableallowallwan` alone does NOT solve this.** That playback only adds a network-layer allow-all rule and disables block-private / block-bogon. It leaves the referer check intact. The fix you actually need is a different playback.
>
> **Fix (verified):** pfSense console option 8 (Shell):
>
> ```text
> pfSsh.php
> ```
>
> At the `pfSense shell:` prompt:
>
> ```
> disablereferercheck
> exit
> ```
>
> Back at the FreeBSD shell prompt:
>
> ```bash
> /etc/rc.restart_webgui
> ```
>
> Then in Kali — open a **private browsing window** (Firefox: Ctrl+Shift+P) so no stale cookie interferes, browse `http://192.168.100.1`, log in. Session sticks this time.
>
> **If still bounced** (rare; only happens if the raw-IP `Host:` header also trips the DNS-rebind check) add this from the same `pfSense shell:` prompt:
>
> ```
> exec
> ```
> (prompt becomes `>>`, paste:)
> ```php
> $config['system']['webgui']['nodnsrebindcheck'] = true;
> write_config("disable dns rebind for lab WAN access");
> ```
> then:
> ```
> exec
> exit
> ```
> and `/etc/rc.restart_webgui` again.
>
> **If you ran `pfctl -d` while diagnosing — re-enable filtering before recording**: `pfctl -e` on the pfSense shell, then `pfctl -s info | head -3` should print `Status: Enabled`. Otherwise the seven-rule WAN recipe is bypassed and every scan in Section 3+ will show every port wide open.

### 4.5 Static route to internal segment (REQUIRED)

The internal subnet `192.168.56.0/24` lives behind R2. pfSense needs a static route, or it will not know where to forward packets destined for the victim.

**System → Routing → Gateways → Add**:
- Interface: LAN
- Name: `R2_INNER_GW`
- Gateway IP: `192.168.66.2`
- Description: `R2 — gateway to internal 192.168.56.0/24`
- Save → Apply Changes

**System → Routing → Static Routes → Add**:
- Destination network: `192.168.56.0/24`
- Gateway: `R2_INNER_GW`
- Description: `Reach victim via R2`
- Save → Apply Changes

### 4.6 Disable Outbound NAT (REQUIRED for firewalking)

**Firewall → NAT → Outbound**:
- Mode: **Manual Outbound NAT rule generation**
- Delete all auto-generated mappings (or leave them disabled)
- Save → Apply Changes

Verify: the Outbound NAT page now shows an empty mapping table. pfSense will route without SNAT. The lab has no internet path, so the absence of NAT does not break anything; it is what lets R2's ICMP Time Exceeded reach Kali with its true source IP.

### 4.7 Allow management from WAN (lab only)

Default pfSense blocks WAN→GUI. We deliberately allow it so Kali can also browse the firewall UI on camera:

**Firewall → Rules → WAN → Add (top)**:
- Action: Pass
- Protocol: TCP
- Source: any
- Destination: WAN address
- Dest port: 80 and 443
- Description: `LAB ONLY — allow GUI from WAN`

> **Disable this rule before any real-network connection. Intentionally unsafe — only valid because WAN is a host-only segment.**

---

## 5. R2 Internal Router (Alpine Linux) — One-Time Setup

R2 sits between pfSense and the victim. Pure IP forwarder. No firewall.

### 5.1 Install media

Download Alpine Standard ISO: `https://alpinelinux.org/downloads/` → `alpine-standard-3.20.x-x86_64.iso`.

### 5.2 VM creation

- Type: Linux / Other Linux (64-bit)
- 1 vCPU, 256 MB RAM, 2 GB disk
- **Network adapter 1**: Host-only → `vboxnet1` (outer / DMZ side; becomes `eth0`)
- **Network adapter 2**: Host-only → `vboxnet2` (inner / victim side; becomes `eth1`)
- Promiscuous mode: **Allow All** on both adapters (needed for packet forwarding and pcap-based tests)

### 5.3 First boot — Alpine `setup-alpine`

Login as `root` (no password on live ISO). Run:

```bash
setup-alpine
```

Answers:
- Keyboard layout: your choice
- Hostname: `r2`
- Network interface to use: `eth0`
  - IP for eth0: `192.168.66.2`
  - Netmask: `255.255.255.0` (when `setup-alpine` asks for "bit count" type **24**, NOT `8` — `8` produces a /8 prefix and breaks routing across both interfaces)
  - Gateway for eth0: `192.168.66.1`
- Configure any other interface: `eth1`
  - IP for eth1: `192.168.56.1`
  - Netmask: `255.255.255.0` (again, **24** if prompted for bit count)
  - Gateway for eth1: *(none — press Enter)*

> **If you already ran setup-alpine with `8`:** check with `ip -4 addr`. If both interfaces show `/8`, fix in-place and persist:
>
> ```bash
> ip addr del 192.168.66.2/8 dev eth0; ip addr add 192.168.66.2/24 dev eth0
> ip addr del 192.168.56.1/8 dev eth1; ip addr add 192.168.56.1/24 dev eth1
> ```
>
> Then edit `/etc/network/interfaces` and replace the lines with the static blocks shown below in §5.4; finally `rc-service networking restart`.
- DNS domain: `lab.local`
- DNS server: `192.168.66.1` (or skip)
- Root password: set one and record it
- Timezone: your choice
- Proxy: none
- NTP client: chrony (default fine)
- SSH server: `openssh`
- Mirror: any
- User: skip (root-only is fine for a lab router)
- Disk to install: `sda` → `sys` (system install) → `y` to erase

Reboot. Remove ISO.

### 5.4 Enable IP forwarding and fix VirtualBox e1000 TSO (run on R2 console after first reboot)

```bash
echo 'net.ipv4.ip_forward = 1' >  /etc/sysctl.d/99-router.conf
sysctl -p /etc/sysctl.d/99-router.conf
sysctl net.ipv4.ip_forward       # should print: net.ipv4.ip_forward = 1

# REQUIRED — enable the sysctl OpenRC service so sysctl.d/ loads at every boot.
# Without this, ip_forward reverts to 0 after reboot; R2 drops transit packets
# silently and the firewalking oracle check in setup-lab.sh fails with 100% loss.
rc-update add sysctl boot
rc-update show boot | grep sysctl   # should print: sysctl | boot
```

**VirtualBox e1000 TSO fix for R2** (same bug that affects the victim — disable offload on both R2 NICs):
```bash
apk add ethtool
ethtool -K eth0 tso off gso off gro off
ethtool -K eth1 tso off gso off gro off
```

Persist across reboots by adding to `/etc/local.d/disable-tso.start`:
```bash
cat > /etc/local.d/disable-tso.start <<'EOF'
#!/bin/sh
/usr/sbin/ethtool -K eth0 tso off gso off gro off
/usr/sbin/ethtool -K eth1 tso off gso off gro off
EOF
chmod +x /etc/local.d/disable-tso.start
rc-update add local default
```

### 5.5 Verify routing tables

```bash
ip -4 addr        # eth0=192.168.66.2/24, eth1=192.168.56.1/24
ip -4 route       # default via 192.168.66.1; 192.168.56.0/24 dev eth1; 192.168.66.0/24 dev eth0
ping -c 2 192.168.66.1    # pfSense LAN reachable
```

### 5.6 No firewall on R2 — intentional

R2 is the **routing oracle** the firewalking technique reads from. It returns ICMP Time Exceeded for any forwarded packet whose TTL expires while traversing it. Adding a filter on R2 would mask pfSense's policy. Leave R2 with default Alpine empty iptables (the default ruleset already accepts and forwards everything).

Confirm:
```bash
iptables -L -n -v     # all chains empty / ACCEPT default
```

Snapshot the VM as `r2-baseline`.

---

## 6. Victim VM (Ubuntu Server) — One-Time Setup from Console

> **Important:** ALL victim configuration happens directly on the Ubuntu console. The course simulates a real external pentest — Kali has ZERO administrative access to the victim. The victim's default gateway is now R2 (192.168.56.1); from the victim's point of view, nothing about that address changed when R2 was introduced.

### 6.1 Install

Download Ubuntu Server 24.04 LTS. Create VM:
- 1 vCPU, 2 GB RAM, 20 GB disk
- **Network adapter 1**: Host-only → `vboxnet2` (internal segment)

During install:
- Hostname: `victim`
- User: `labuser`
- Install OpenSSH Server: **yes**
- No additional snaps.

### 6.2 Network — static internal IP (run on victim console)

```bash
sudo tee /etc/netplan/99-lab.yaml >/dev/null <<'EOF'
network:
  version: 2
  ethernets:
    enp0s3:
      dhcp4: false
      addresses: [192.168.56.20/24]
      routes:
        - to: default
          via: 192.168.56.1
      nameservers:
        addresses: [1.1.1.1, 9.9.9.9]
EOF
sudo chmod 600 /etc/netplan/99-lab.yaml
sudo netplan apply
ip -4 addr show enp0s3         # confirm 192.168.56.20
ping -c1 192.168.56.1          # confirm R2 reachable as default GW
ping -c1 192.168.66.1          # confirm reach to pfSense LAN through R2
```

> Adjust interface name (`enp0s3`) to whatever `ip link` shows on your VM.

### 6.3 Fix VirtualBox e1000 TSO bug (REQUIRED — see Appendix B)

VirtualBox's emulated Intel `e1000` adapter combined with Linux TSO produces sporadic `e1000 enp0s3: Reset adapter` events that drop traffic mid-stream. Disable offload features on the victim NIC, persistently:

```bash
# One-shot, current session
sudo ethtool -K enp0s3 tso off gso off gro off

# Persist via networkd-dispatcher
sudo tee /etc/networkd-dispatcher/routable.d/50-disable-offload.sh >/dev/null <<'EOF'
#!/bin/sh
/usr/sbin/ethtool -K enp0s3 tso off gso off gro off || true
EOF
sudo chmod +x /etc/networkd-dispatcher/routable.d/50-disable-offload.sh
```

### 6.4 Services and tools — install on victim console

> **Internet required.** Do this step before switching the victim NIC to host-only-only. If the VM was installed with a NAT adapter for internet access, keep it attached until all packages are installed, then remove it and snapshot.

```bash
sudo apt update
sudo apt install -y nginx socat python3-scapy iodine dns2tcp
sudo systemctl enable --now nginx
sudo systemctl enable --now ssh
```

**Chisel** (not in apt — must download during initial setup while VM has internet):
```bash
CHISEL_VER=1.9.1
wget -q "https://github.com/jpillora/chisel/releases/download/v${CHISEL_VER}/chisel_${CHISEL_VER}_linux_amd64.gz" \
  -O /tmp/chisel.gz
gunzip /tmp/chisel.gz
chmod +x /tmp/chisel
sudo mv /tmp/chisel /usr/local/bin/chisel
chisel --version
```

### 6.5 Python HTTP server on port 8080 (persistent via systemd)

```bash
sudo tee /etc/systemd/system/lab-http-8080.service >/dev/null <<'EOF'
[Unit]
Description=Lab HTTP server on port 8080
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 -m http.server 8080 --bind 0.0.0.0
Restart=always
User=labuser

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now lab-http-8080.service
```

### 6.6 Verify services running

```bash
ss -ltn
```

Expected:
```
LISTEN 0  511   0.0.0.0:80    (nginx)
LISTEN 0  4096  0.0.0.0:22    (sshd)
LISTEN 0  5     0.0.0.0:8080  (python http.server)
```

Snapshot the VM as `victim-baseline`.

### 6.7 No SSH from Kali — intentional

The pentester operates from Kali with **no administrative access** to anything behind the firewall. This is realistic:
- Real engagements don't include backdoor admin access
- Firewall must be tested as a true external attacker would see it
- All Kali commands work through the firewall as observed traffic

---

## 7. pfSense Firewall Rule Recipe

> **Critical:** Rules go on **WAN interface**, NOT LAN. Kali sits on the WAN side; traffic from Kali to victim is processed by WAN rules. Destination IPs in the rules continue to reference `192.168.56.20` (the victim) — pfSense matches by destination address, routes the matched packet via the static route to R2, and R2 forwards to the victim.

`Firewall → Rules → WAN`. Default WAN denies all inbound. Add **in this order, top to bottom**:

| # | Action | Proto | Source | Dest | Dest Port | Description |
|---|---|---|---|---|---|---|
| 1 | **Pass** | ICMP | any | WAN address | — | Allow ping to pfSense WAN |
| 2 | **Pass** | TCP | any | WAN address | 80 | Allow HTTP to pfSense GUI |
| 3 | **Pass** | TCP | any | WAN address | 443 | Allow HTTPS to pfSense GUI |
| 4 | **Pass** | TCP | any | `192.168.56.20` | 80 | Allow HTTP to victim → SYN reports `open` |
| 5 | **Pass** | TCP | any | `192.168.56.20` | 8080 | Allow alt-HTTP to victim → SYN reports `open` |
| 6 | **Block** | TCP | any | `192.168.56.20` | 22 | Block SSH → SYN reports `filtered` |
| 7 | **Block** | TCP | any | `192.168.56.20` | 443 | Block HTTPS → SYN reports `filtered` |

**Important:** Do NOT add a broad "PASS any → 192.168.56.0/24" rule. It will override the BLOCK rules above and break the demo.

Click **Apply Changes** in the yellow banner.

### 7.1 LAN interface rules (REQUIRED edit — do not skip)

pfSense's default LAN rule source is `LAN net` = 192.168.66.0/24 (the directly connected DMZ segment). The victim lives on 192.168.56.0/24 — a routed subnet behind R2 — and does NOT match `LAN net`. Without this fix, all victim-initiated outbound traffic (egress tests in S4.3, tunneling demos in S5, ICMP covert channel in S5.2/S8.4) is silently dropped by pfSense.

**Firewall → Rules → LAN → edit the default allow rule**:
- Source: change from `LAN net` → **`any`**
- Save → Apply Changes

Verify from victim console after applying:
```bash
ping -c 2 192.168.100.50    # must succeed — victim → Kali through pfSense
```

If ping replies arrive, egress is open. If 100% loss, the rule change did not apply — check that you saved AND clicked Apply Changes.

---

## 8. Kali Attacker — minimal config

Already shipped with most required tools. Confirm and install anything missing:

```bash
sudo apt update
sudo apt install -y nmap hping3 ncat python3-scapy iodine dns2tcp ettercap-text-only bettercap fragroute pandoc
which nmap hping3 nc scapy iodine dns2tcp ettercap bettercap fragroute pandoc
```

**Chisel** (not in apt — download during initial Kali setup while VM has internet):
```bash
CHISEL_VER=1.9.1
wget -q "https://github.com/jpillora/chisel/releases/download/v${CHISEL_VER}/chisel_${CHISEL_VER}_linux_amd64.gz" \
  -O /tmp/chisel.gz
gunzip /tmp/chisel.gz
chmod +x /tmp/chisel
sudo mv /tmp/chisel /usr/local/bin/chisel
chisel --version
```

Static IP on WAN segment:
```bash
sudo nmcli con mod "Wired connection 1" ipv4.method manual \
  ipv4.addresses 192.168.100.50/24 ipv4.gateway 192.168.100.1
sudo nmcli con up   "Wired connection 1"
```

Persistent /32 host route — forces victim-bound traffic via pfSense, not via eth1 directly.

**Why this is required:** Kali eth1 (192.168.56.30/24, added for Section 6 ARP MiTM) creates a kernel connected route `192.168.56.0/24 dev eth1`. hping3 and nmap resolve the destination MAC using the routing table: they find the /24 via eth1, ARP directly on eth1, get victim's MAC, then embed it in Ethernet frames sent on eth0. VirtualBox vboxnet0 drops those frames — victim's MAC is unknown there. A /32 host route beats the /24 by prefix length, forcing ARP to resolve pfSense WAN gateway MAC on eth0 instead.

**Do NOT use `nmcli con mod "Wired connection 1"`** — that profile manages eth1, not eth0. The route would land on eth1 and not help.

Instead, use an NM dispatcher script (runs when NM brings eth0 up; persists across reboots):
```bash
sudo tee /etc/NetworkManager/dispatcher.d/10-victim-route.sh >/dev/null <<'EOF'
#!/bin/bash
[[ "$1" == "eth0" && "$2" == "up" ]] && \
  ip route replace 192.168.56.20/32 via 192.168.100.1 dev eth0 2>/dev/null || true
EOF
sudo chmod +x /etc/NetworkManager/dispatcher.d/10-victim-route.sh
```

Trigger it manually for the current session (no reboot needed):
```bash
sudo ip route replace 192.168.56.20/32 via 192.168.100.1 dev eth0
ip route show 192.168.56.20    # should print: 192.168.56.20 via 192.168.100.1 dev eth0
```

`setup-lab.sh` also injects this route as a safety net at the start of every session.

---

## 9. Smoke Test (run before every recording)

```bash
cd /Users/dimitrisamprazis/Downloads/Firewall_Course_Build
./setup-lab.sh             # verify all four VMs + routing + rules
```

Expected green output:
```
[+] Kali on WAN segment (192.168.100.0/24)
[+] pfSense WAN reachable
[+] Static route to 192.168.56.0/24 working (pfSense → R2 → victim)
[+] R2 returns ICMP Time Exceeded on TTL=2 probes (firewalk oracle live)
[+] SYN: 80/tcp open
[+] SYN: 8080/tcp open
[+] SYN: 22/tcp filtered
[+] SYN: 443/tcp filtered
[+] ACK: stateful 'filtered' responses present
[+] Lab ready. You can record.
```

If any check fails, the script tells you exactly which VM, route, or rule to fix.

**Manual egress check (run once from victim console after initial setup):**

`setup-lab.sh` runs only from Kali and cannot test victim-initiated outbound traffic. After completing §7.1 (LAN rule → `any`), verify egress manually from victim console:

```bash
ping -c 2 192.168.100.50    # victim → Kali — must succeed
```

If 100% loss: pfSense `Firewall → Rules → LAN` default allow rule Source is still `LAN net` — change it to `any` and Apply Changes.

---

## 10. Snapshots

After everything verified working, snapshot every VM with the label `clean-lab-baseline`:

- Kali  → `clean-lab-baseline`
- pfSense → `clean-lab-baseline-rules-applied`
- R2 → `r2-baseline`
- Victim → `victim-baseline`

---

## 11. Reset Procedure

```bash
# 1. revert all four VMs to baseline snapshots
# 2. on Kali:
cd /Users/dimitrisamprazis/Downloads/Firewall_Course_Build
./setup-lab.sh verify
```

Lab returns to deterministic green in under 60 seconds.

---

## Appendix A — Default Credentials & IPs (single source of truth)

| Asset | Address | User | Password |
|---|---|---|---|
| pfSense WAN (admin GUI) | `192.168.100.1` | `admin` | *set during wizard* |
| pfSense LAN (interior) | `192.168.66.1` | n/a | n/a |
| R2 outer | `192.168.66.2` | `root` | *set during setup-alpine* |
| R2 inner (victim GW) | `192.168.56.1` | n/a | n/a |
| Kali attacker | `192.168.100.50` | `kali` | *set during install* |
| Victim Ubuntu | `192.168.56.20` | `labuser` | *set during install* |

Update `setup-lab.sh` env vars if any of the above change.

## Appendix B — VirtualBox e1000 TSO Bug

Symptoms: random `e1000 enp0s3: Reset adapter` in victim dmesg; `curl` returns exit-code 000; egress tests hang. Fix: disable TCP/Generic/Generic-Receive Segmentation Offload on the victim NIC (§6.3). Not VirtualBox-version-specific; persists across 7.x releases.
