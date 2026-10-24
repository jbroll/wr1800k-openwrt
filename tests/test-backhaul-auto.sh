#!/bin/sh
# Tests for backhaul-auto. Stubs device commands as shell functions, sources
# the script with AUTO_LIB=1, and drives start() and check() through each state.
# Usage: sh tests/test-backhaul-auto.sh

S=$0; D=$(dirname "$S")/..
PASS=0; FAIL=0

# --- stubs (overridden per test) ---
STUB_CARRIER=0; STUB_OFFER=0; STUB_GW=192.168.1.1; STUB_PING=1
PROTO=none; WWAN_DIS=0; AP_DIS=1; PSTAD_LAST=""
udhcpc() { [ "$STUB_OFFER" = 1 ]; }
ping() { [ "$STUB_PING" = 1 ]; }
uci() {
	case "$*" in
	"-q get network.lan.proto") echo "$PROTO" ;;
	"-q get wireless.wwan.device") echo radio1 ;;
	"show wireless") printf '%s\n' "wireless.default_radio0.device='radio0'" "wireless.default_radio1.device='radio1'" ;;
	"set network.lan.proto="*) PROTO=${2#*=} ;;
	"set wireless.wwan.disabled="*) WWAN_DIS=${2#*=} ;;
	"set wireless.default_radio1.disabled="*) AP_DIS=${2#*=} ;;
	esac
	return 0
}
pstad_stub() { PSTAD_LAST=$1; }
reload_config() { return 0; }
logger() { return 0; }
sleep() { return 0; }

AUTO_LIB=1; AUTO_PSTAD=pstad_stub; . "$D/backhaul-auto"

# the script defines these, so their stubs go after it
carrier() { [ "$STUB_CARRIER" = 1 ]; }
gateway() { echo "$STUB_GW"; }

ok() {  # NAME GOT WANT
	if [ "$2" = "$3" ]; then PASS=$(( PASS + 1 )); else FAIL=$(( FAIL + 1 )); echo "FAIL: $1 (got $2, want $3)"; fi
}

proxy_state() { STATE=proxy; FAILS=0; PROTO=none; WWAN_DIS=0; AP_DIS=1; PSTAD_LAST=""; }
wired_state() { STATE=wired; FAILS=0; PROTO=dhcp; WWAN_DIS=1; AP_DIS=0; PSTAD_LAST=""; }

# 1. backhaul_ap finds the AP on the station's radio
BH_AP=$(backhaul_ap)
ok "backhaul-ap" "$BH_AP" default_radio1

# 2. proxy with no carrier never switches
proxy_state; STUB_CARRIER=0; STUB_OFFER=1
check
ok "proxy-no-carrier-stays" "$STATE" proxy

# 3. carrier without a DHCP server stays proxy: a wired client, not an uplink
proxy_state; STUB_CARRIER=1; STUB_OFFER=0
check
ok "proxy-client-only-stays" "$STATE" proxy

# 4. a DHCP offer on the wire switches to wired at once
proxy_state; STUB_CARRIER=1; STUB_OFFER=1
check
ok "offer-switches-wired" "$STATE" wired
ok "offer-stops-pstad" "$PSTAD_LAST" stop
ok "offer-lan-dhcp" "$PROTO" dhcp
ok "offer-station-off" "$WWAN_DIS" 1
ok "offer-backhaul-ap-on" "$AP_DIS" 0

# 5. a healthy wire keeps wired
wired_state; STUB_CARRIER=1; STUB_PING=1
check; check; check
ok "wired-healthy-stays" "$STATE" wired

# 6. wired falls back to proxy only after REQUIRE straight failures
wired_state; STUB_CARRIER=0
check; check
ok "wired-grace" "$STATE" wired
check
ok "wired-third-fail-proxy" "$STATE" proxy
ok "fallback-starts-pstad" "$PSTAD_LAST" start
ok "fallback-lan-none" "$PROTO" none
ok "fallback-station-on" "$WWAN_DIS" 0
ok "fallback-backhaul-ap-off" "$AP_DIS" 1

# 7. a failure followed by recovery clears the count
wired_state; STUB_CARRIER=1; STUB_PING=0
check; check
STUB_PING=1
check
ok "wired-flap-clears" "$FAILS" 0
ok "wired-flap-stays" "$STATE" wired

# 8. wired with no lease yet counts as a failure
wired_state; STUB_CARRIER=1; STUB_GW=""
check
ok "wired-no-gateway-fails" "$FAILS" 1
STUB_GW=192.168.1.1

# 9. start resumes wired from the saved config without touching pstad
wired_state; STATE=; STUB_CARRIER=0; STUB_OFFER=0
start
ok "start-resumes-wired" "$STATE" wired
ok "start-resume-no-pstad" "$PSTAD_LAST" ""

# 10. start on a proxy config with a wire goes wired and never starts pstad
proxy_state; STATE=; STUB_CARRIER=1; STUB_OFFER=1
start
ok "start-wire-goes-wired" "$STATE" wired
ok "start-wire-pstad-stopped" "$PSTAD_LAST" stop

# 11. start on a proxy config with no wire starts pstad
proxy_state; STATE=; STUB_CARRIER=0
start
ok "start-no-wire-proxy" "$STATE" proxy
ok "start-no-wire-pstad" "$PSTAD_LAST" start

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" = 0 ]
