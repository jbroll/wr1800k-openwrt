#!/bin/sh
# Tests for wwan-watchdog. Stubs device commands as shell functions, sources
# the script with WWAN_LIB=1, and drives check() through each state.
# Usage: sh tests/test-wwan-watchdog.sh

S=$0; D=$(dirname "$S")/..
PASS=0; FAIL=0

# --- stubs (overridden per test) ---
STUB_LS="phy1-sta0"; STUB_UP=1; STUB_LINKED=1
BOUNCES=0
ls() { echo "$STUB_LS"; }
ubus() { [ "$STUB_UP" = 1 ] && echo '"up": true' || echo '"up": false'; return 0; }
iw() { [ "$STUB_LINKED" = 1 ] && echo 'Connected to 3c:bd:c5:41:b2:ec' || echo 'Not connected.'; return 0; }
ifdown() { return 0; }
ifup() { return 0; }
sleep() { return 0; }
logger() { return 0; }

WWAN_LIB=1; . "$D/wwan-watchdog"

# bounce() counts instead of touching the network
bounce() { BOUNCES=$(( BOUNCES + 1 )); DOWN=0; }

ok() {  # NAME COND...
	if [ "$2" = "$3" ]; then PASS=$(( PASS + 1 )); else FAIL=$(( FAIL + 1 )); echo "FAIL: $1 (got $2, want $3)"; fi
}

# 1. associated link never bounces
STUB_UP=1; STUB_LINKED=1; DOWN=0; BOUNCES=0
check; check; check
ok "linked-no-bounce" "$BOUNCES" 0

# 2. wwan down never bounces and clears the counter
STUB_UP=0; STUB_LINKED=0; DOWN=2; BOUNCES=0
check
ok "wwan-down-no-bounce" "$BOUNCES" 0
ok "wwan-down-clears" "$DOWN" 0

# 3. three straight unassociated checks bounce exactly once
STUB_UP=1; STUB_LINKED=0; DOWN=0; BOUNCES=0
check; check
ok "grace-no-early-bounce" "$BOUNCES" 0
check
ok "third-down-bounces" "$BOUNCES" 1
check; check
ok "counter-reset-after-bounce" "$BOUNCES" 1

# 4. recovery before grace never bounces
STUB_UP=1; STUB_LINKED=0; DOWN=0; BOUNCES=0
check; check
STUB_LINKED=1
check
ok "flap-no-bounce" "$BOUNCES" 0
ok "flap-clears" "$DOWN" 0

# 5. no STA interface is a no-op
STUB_LS=""; DOWN=0; BOUNCES=0
check
ok "no-backhaul-noop" "$BOUNCES" 0

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" = 0 ]
