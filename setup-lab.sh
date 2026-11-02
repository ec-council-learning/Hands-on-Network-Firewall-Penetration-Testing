#!/usr/bin/env bash
# =============================================================================
# setup-lab.sh
# External-only lab verification for the course
# "Hands-On Network Firewall Penetration Testing".
#
# WHAT THIS SCRIPT DOES
#   1. Validates Kali can reach the pfSense WAN interface.
#   2. Confirms the static route through pfSense to R2 to victim works
#      (pfSense routes 192.168.56.0/24 via 192.168.66.2).
#   3. Confirms R2 returns ICMP Time Exceeded on probes whose TTL expires
#      AT R2 — this is the firewalking oracle Section 4 relies on.
#   4. Runs a full rehearsal of the on-camera Nmap commands and checks the
#      output matches what the recording script expects.
#
# WHAT THIS SCRIPT DOES NOT DO
#   - Does NOT SSH to the victim. Pentester has no admin access during testing.
#   - Does NOT touch pfSense or R2. Config applied via console / Web UI per
#     lab_layout_and_setup.md.
#
# USAGE
#   ./setup-lab.sh            # run all checks (default)
#   ./setup-lab.sh verify     # same as above
#
# ENV VARS (override if the lab uses different addressing)
#   PFSENSE_WAN    default 192.168.100.1     (pfSense WAN gateway)
#   PFSENSE_LAN    default 192.168.66.1      (pfSense LAN — DMZ side)
#   R2_OUTER       default 192.168.66.2      (R2 outer — same DMZ subnet)
#   R2_INNER       default 192.168.56.1      (R2 inner — victim GW)
#   TARGET_IP      default 192.168.56.20     (victim host)
#   KALI_IF        default eth0              (Kali interface on WAN segment)
#
# =============================================================================

set -Euo pipefail

PFSENSE_WAN="${PFSENSE_WAN:-192.168.100.1}"
PFSENSE_LAN="${PFSENSE_LAN:-192.168.66.1}"
R2_OUTER="${R2_OUTER:-192.168.66.2}"
R2_INNER="${R2_INNER:-192.168.56.1}"
TARGET_IP="${TARGET_IP:-192.168.56.20}"
KALI_IF="${KALI_IF:-eth0}"

# ---- pretty output -----------------------------------------------------------
C_GREEN=$'\033[0;32m'; C_RED=$'\033[0;31m'; C_YEL=$'\033[0;33m'
C_CYAN=$'\033[0;36m'; C_BOLD=$'\033[1m'; C_RST=$'\033[0m'
say()  { printf '%s[*]%s %s\n' "$C_CYAN" "$C_RST" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$C_GREEN" "$C_RST" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_YEL"   "$C_RST" "$*"; }
err()  { printf '%s[x]%s %s\n' "$C_RED"   "$C_RST" "$*" >&2; }
hr()   { printf '%s------------------------------------------------------------%s\n' "$C_BOLD" "$C_RST"; }

# ---- prerequisite checks -----------------------------------------------------
check_prereqs() {
  hr; say "Checking prerequisites on Kali"
  for bin in nmap nc hping3; do
    if ! command -v "$bin" >/dev/null 2>&1; then
      err "Missing required binary: $bin"; exit 1
    fi
  done
  ok "Required Kali binaries present: nmap, nc, hping3"

  say "Verifying $KALI_IF interface has an IP on the WAN segment (192.168.100.0/24)"
  if ! ip -4 addr show "$KALI_IF" 2>/dev/null | grep -q 'inet 192.168.100\.'; then
    err "Interface $KALI_IF has no IPv4 address on 192.168.100.0/24."
    err "Configure with: sudo ip addr add 192.168.100.50/24 dev $KALI_IF"
    exit 1
  fi
  ok "Kali on WAN segment (192.168.100.0/24)"

  say "Pinging pfSense WAN gateway ($PFSENSE_WAN)"
  ping -c 1 -W 2 "$PFSENSE_WAN" >/dev/null 2>&1 || {
    err "pfSense WAN $PFSENSE_WAN unreachable. Check pfSense ICMP rule on WAN."
    exit 1
  }
  ok "pfSense WAN reachable"
}

# ---- routing oracle checks ---------------------------------------------------
check_routing() {
  hr; say "Checking pfSense static route through R2 to victim"

  # A SYN to victim:80 at TTL=2 should expire AT R2 (.66.2) and produce
  # an ICMP Time Exceeded sourced from R2's outer IP. That is the
  # classical firewalking signal Section 4.4 relies on.
  local out
  out="$(sudo hping3 -I "$KALI_IF" -c 1 -S -p 80 -t 2 "$TARGET_IP" 2>&1 || true)"

  if grep -q "TTL 0 during transit from ip=$R2_OUTER" <<<"$out"; then
    ok "R2 returns ICMP Time Exceeded on TTL=2 (firewalk oracle live)"
  else
    err "R2 did NOT return ICMP Time Exceeded on TTL=2."
    err "Likely causes (check in order):"
    err "  1. pfSense Outbound NAT still on Automatic — switch to Manual with no mappings."
    err "  2. pfSense static route 192.168.56.0/24 via $R2_OUTER missing."
    err "  3. R2 net.ipv4.ip_forward != 1, or R2 interfaces misconfigured."
    err "  4. Kali eth1 (56.x) is up — hping must use $KALI_IF to probe via pfSense WAN."
    err "Got:"; echo "$out" | head -5 >&2
    exit 1
  fi

  # A SYN to victim:80 at TTL=3 should reach the victim and return SYN-ACK.
  out="$(sudo hping3 -I "$KALI_IF" -c 1 -S -p 80 -t 3 "$TARGET_IP" 2>&1 || true)"
  if grep -q "ttl=.* flags=SA" <<<"$out"; then
    ok "Victim reachable at hop 3 (SYN-ACK on port 80 with TTL=3 probe)"
  else
    err "Victim did NOT reply to SYN @ TTL=3. Check R2 forwarding and victim nginx."
    err "Got:"; echo "$out" | head -5 >&2
    exit 1
  fi
}

# ---- rehearsal: on-camera Nmap commands and validation ----------------------
rehearsal() {
  hr; say "Rehearsing Nmap commands against victim $TARGET_IP"

  local syn_out ack_out frag_out
  syn_out="$(sudo nmap -sS -Pn -e "$KALI_IF" -p 22,80,443,8080 "$TARGET_IP" 2>/dev/null || true)"
  ack_out="$(sudo nmap -sA -Pn -e "$KALI_IF" -p 22,80,443,8080 "$TARGET_IP" 2>/dev/null || true)"
  frag_out="$(sudo nmap -sS -Pn -e "$KALI_IF" -f -p 443        "$TARGET_IP" 2>/dev/null || true)"

  echo "---- SYN scan ----"; echo "$syn_out"
  echo "---- ACK scan ----"; echo "$ack_out"
  echo "---- Fragmented SYN (443) ----"; echo "$frag_out"

  hr; say "Validating against recording-script expectations"
  local fail=0

  if ! grep -Eq '^80/tcp[[:space:]]+open'      <<<"$syn_out"; then
    err "SYN: port 80 not 'open'. Check pfSense WAN Rule 4 + nginx on victim."; fail=1
  else
    ok "SYN: 80/tcp open"
  fi
  if ! grep -Eq '^8080/tcp[[:space:]]+open'    <<<"$syn_out"; then
    err "SYN: port 8080 not 'open'. Check pfSense WAN Rule 5 + python http on victim."; fail=1
  else
    ok "SYN: 8080/tcp open"
  fi
  if ! grep -Eq '^22/tcp[[:space:]]+filtered'  <<<"$syn_out"; then
    err "SYN: port 22 not 'filtered'. Check pfSense WAN Rule 6 (Block SSH)."; fail=1
  else
    ok "SYN: 22/tcp filtered"
  fi
  if ! grep -Eq '^443/tcp[[:space:]]+filtered' <<<"$syn_out"; then
    err "SYN: port 443 not 'filtered'. Check pfSense WAN Rule 7 (Block HTTPS)."; fail=1
  else
    ok "SYN: 443/tcp filtered"
  fi

  if ! grep -Eq 'filtered' <<<"$ack_out"; then
    warn "ACK scan produced no 'filtered' entries — review pfSense stateful posture."
  else
    ok "ACK: stateful 'filtered' responses present"
  fi

  if (( fail == 0 )); then
    hr; ok "${C_BOLD}Lab ready.${C_RST}"
  else
    hr; err "${C_BOLD}Lab NOT ready.${C_RST} Fix issues above, then re-run: ./setup-lab.sh"
    exit 1
  fi
}

main() {
  local action="${1:-verify}"
  case "$action" in
    verify|start)
      check_prereqs
      check_routing
      rehearsal
      ;;
    *)
      err "Unknown action: $action"
      echo "Usage: $0 [verify]" >&2
      exit 2
      ;;
  esac
}

main "$@"
