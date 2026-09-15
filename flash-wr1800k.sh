#!/usr/bin/env bash
#
# flash-wr1800k.sh: build a credentialed OpenWrt image for the Fenvi WR1800K
# (MediaTek MT7621, OpenWrt sim_simax1800t profile) and flash it via the stock
# U-Boot network-boot path. See docs/architecture.md for background and
# docs/user-manual.md for the manual flow.
#
# Reads credentials from creds.json, builds a sysupgrade image with the root
# password (optional), SSH authorized keys, Wi-Fi, hostname/mDNS name and umdns
# baked in, RAM-boots the stock initramfs over TFTP, sysupgrades onto NAND, then
# verifies over SSH (key-based) and prints the device's address and mDNS name.
#
# Usage:  sudo ./flash-wr1800k.sh [creds.json] <wired-iface>
#         ./flash-wr1800k.sh [creds.json] build
#   creds.json    credentials file            (default: ./creds.json)
#   wired-iface   host NIC cabled to a LAN port on the router (required)
#   build         build the image only and print its path; no sudo, no NIC
#
# The only manual step is one power-cycle of the router when prompted.
#
# Assumes the stock initramfs allows passwordless root over SSH (standard on a
# fresh OpenWrt). If it does not, use the serial method in docs/user-manual.md.

set -euo pipefail

# ---- configuration ----
VER="${OPENWRT_VERSION:-24.10.0}"
PROFILE="sim_simax1800t"
IB_NAME="openwrt-imagebuilder-${VER}-ramips-mt7621.Linux-x86_64"
DL="https://downloads.openwrt.org/releases/${VER}/targets/ramips/mt7621"

HOST_RECOVERY_IP="192.168.1.254"   # address U-Boot's TFTP recovery expects
DEVICE_IP="192.168.1.1"            # OpenWrt default LAN (initramfs and install)
UBOOT_IP="${OPENWRT_UBOOT_IP:-192.168.1.222}"   # U-Boot's own IP during factory-boot TFTP (per-unit; overridable)
HEXLEN=6                           # trailing MAC hex digits (last 3 bytes) in the hostname

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR"

# ---- args ----
CREDS="${1:-creds.json}"
IFACE="${2:-}"
[ -n "$IFACE" ] || { echo "usage: sudo $0 [creds.json] <wired-iface>|build" >&2; exit 2; }
[ -f "$CREDS" ]  || { echo "creds file not found: $CREDS" >&2; exit 2; }
BUILD_ONLY=0; [ "$IFACE" = build ] && BUILD_ONLY=1
[ "$BUILD_ONLY" = 1 ] || ip link show "$IFACE" >/dev/null 2>&1 || { echo "no such interface: $IFACE" >&2; exit 2; }

msg() { printf '\n=== %s ===\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing dependency: $1"; }
for c in jq openssl curl tar zstd ssh-keygen; do need "$c"; done
[ "$BUILD_ONLY" = 1 ] || for c in in.tftpd ssh sshpass nc ip; do need "$c"; done

SUDO="sudo"; [ "$(id -u)" = 0 ] && SUDO=""

WORK="$(cd "$(dirname "$0")" && pwd)/build"
TFTPROOT="$WORK/tftproot"
FILES="$WORK/files"
AUTOKEY="$WORK/id_flash"           # script's own key, baked in for key-based verify

# ---- credentials ----
ROOT_PW=$(jq -r '.root_password // ""' "$CREDS")
MAIN_SSID=$(jq -r '.main_ssid // .wifi_ssid // ""' "$CREDS")
AP_SSID=$(jq -r '.ap_ssid // ""' "$CREDS")
WIFI_KEY=$(jq -r '.wifi_password // .wifi_key // ""' "$CREDS")
COUNTRY=$(jq -r '.country // "US"' "$CREDS")
PREFIX=$(jq -r '.hostname_prefix // "WR1800K"' "$CREDS")
ENC=$(jq -r '.wifi_encryption // "sae-mixed"' "$CREDS")
LAN_IPADDR=$(jq -r '.lan_ipaddr // "192.168.9.1"' "$CREDS")   # flashed LAN; non-overlapping with a typical home 192.168.1.0/24
MODE=$(jq -r '.mode // "ap"' "$CREDS")                        # ap | bridge
BACKHAUL=$(jq -r '.backhaul // "relayd"' "$CREDS")            # bridge uplink: relayd | wds | wired | proxy
BACKHAUL_BAND=$(jq -r '.backhaul_band // "5"' "$CREDS")       # 2 or 5 (GHz) radio for a wireless backhaul (relayd/wds/proxy)
SSH_KEYS=$(jq -r '(.ssh_authorized_keys // []) | if type=="array" then join("\n") else tostring end' "$CREDS")
[ "$SSH_KEYS" = null ] && SSH_KEYS=""
# optional automatic power-cycle: a local-env feature (e.g. a smart plug). If both
# commands are set (env var overrides creds.json), step 3 cycles power itself
# instead of prompting for a manual unplug/replug.
POWER_OFF_CMD="${POWER_OFF_CMD:-$(jq -r '.power_off_cmd // ""' "$CREDS")}"
POWER_ON_CMD="${POWER_ON_CMD:-$(jq -r '.power_on_cmd // ""' "$CREDS")}"
[ "$POWER_OFF_CMD" = null ] && POWER_OFF_CMD=""
[ "$POWER_ON_CMD" = null ] && POWER_ON_CMD=""
case "$MODE" in ap|bridge) ;; *) die "mode must be ap or bridge (got: $MODE)";; esac
case "$BACKHAUL" in relayd|wds|wired|proxy) ;; *) die "backhaul must be relayd, wds, wired or proxy (got: $BACKHAUL)";; esac
if [ "$MODE" = bridge ] && [ "$BACKHAUL" != wired ]; then
	{ [ -n "$MAIN_SSID" ] && [ "$MAIN_SSID" != null ]; } || die "wireless backhaul ($BACKHAUL) needs main_ssid (the upstream network to join)"
fi
# ap_ssid overrides main_ssid for the broadcast network; blank => broadcast main_ssid
if [ -n "$AP_SSID" ] && [ "$AP_SSID" != null ]; then WIFI_SSID="$AP_SSID"; else WIFI_SSID="$MAIN_SSID"; fi
# root password is optional when an SSH key is supplied
if [ -n "$ROOT_PW" ] && [ "$ROOT_PW" != null ]; then ROOT_HASH=$(openssl passwd -6 "$ROOT_PW"); else ROOT_HASH=""; fi
[ -n "$WIFI_SSID" ] && [ "$WIFI_SSID" != null ] || die "SSID missing in $CREDS (main_ssid or ap_ssid)"
[ -n "$ROOT_HASH" ] || [ -n "$SSH_KEYS" ] || die "provide root_password or ssh_authorized_keys in $CREDS"
case "$WIFI_SSID$WIFI_KEY" in *[\"\`\\\']*) die "SSID/key may not contain \" ' \` or backslash";; esac

TFTPD_PID=""; NM_UNMANAGED=0; FW_ADDED=0; VHOST_ADDED=0
cleanup() {
	# $TFTPD_PID is sudo's pid, not in.tftpd's, so match the daemon by its args
	$SUDO pkill -f "in.tftpd.*$TFTPROOT" 2>/dev/null || true
	$SUDO pkill -f "tcpdump -ni $IFACE" 2>/dev/null || true   # U-Boot IP discovery sniffer
	[ "$FW_ADDED" = 1 ]     && $SUDO iptables -D INPUT -i "$IFACE" -p udp --dport 69 -j ACCEPT 2>/dev/null || true
	$SUDO ip route del "$UBOOT_IP/32" dev "$IFACE" 2>/dev/null || true
	$SUDO ip route del "$DEVICE_IP/32" dev "$IFACE" 2>/dev/null || true
	$SUDO ip addr del "$HOST_RECOVERY_IP/32" dev "$IFACE" 2>/dev/null || true
	[ "$VHOST_ADDED" = 1 ] && $SUDO ip addr del "${LAN_IPADDR%.*}.254/24" dev "$IFACE" 2>/dev/null || true
	[ "$NM_UNMANAGED" = 1 ] && $SUDO nmcli device set "$IFACE" managed yes 2>/dev/null || true
}
[ "$BUILD_ONLY" = 1 ] || trap cleanup EXIT

# =====================================================================
msg "1/5  build credentialed image"
mkdir -p "$WORK" "$TFTPROOT"; cd "$WORK"

if [ ! -d "$IB_NAME" ]; then
	echo "downloading ImageBuilder ${VER}..."
	curl -fL -o ib.tar.zst "$DL/${IB_NAME}.tar.zst"
	tar --zstd -xf ib.tar.zst
fi

rm -rf "$FILES"; mkdir -p "$FILES/etc/uci-defaults" "$FILES/etc/umdns" "$FILES/etc/dropbear" "$FILES/etc/hotplug.d/iface" \
	"$FILES/usr/sbin" "$FILES/etc/init.d" "$FILES/etc/psta"

# first-boot provisioning: bake the creds.json values into a variable header,
# then append the mode-aware logic from provision.sh. Values are single-quoted
# so a '$' in a hash/key/SSID is not expanded by the device shell (SSID and key
# are validated above to contain no quote/backtick/backslash).
SRCDIR="$(dirname "$WORK")"   # WORK is the absolute <repo>/build, so its parent is the script dir
[ -f "$SRCDIR/provision.sh" ] || die "provision.sh not found next to the flasher"
{
	echo "#!/bin/sh"
	echo "MODE='${MODE}'"
	echo "BACKHAUL='${BACKHAUL}'"
	echo "ROOT_HASH='${ROOT_HASH}'"
	echo "PREFIX='${PREFIX}'"
	echo "UPSTREAM_SSID='${MAIN_SSID}'"
	echo "AP_SSID='${WIFI_SSID}'"
	echo "ENC='${ENC}'"
	echo "KEY='${WIFI_KEY}'"
	echo "COUNTRY='${COUNTRY}'"
	echo "LAN_IPADDR='${LAN_IPADDR}'"
	echo "BACKHAUL_BAND='${BACKHAUL_BAND}'"
	echo
	sed '1{/^#!/d;}' "$SRCDIR/provision.sh"
} > "$FILES/etc/uci-defaults/99-provision"
chmod +x "$FILES/etc/uci-defaults/99-provision"

cat > "$FILES/etc/umdns/router.json" <<'UMDNS'
{
	"router_ssh":  { "service": "_ssh._tcp.local",  "port": 22 },
	"router_http": { "service": "_http._tcp.local", "port": 80 }
}
UMDNS

# relayd launcher for repeater mode: when the wwan STA interface comes up, start
# relayd to proxy-ARP and DHCP-relay between the LAN and the STA (many ISP
# routers, Verizon Fios for example, do not bridge WDS 4-address frames, so this
# is how repeater clients get an upstream-subnet address). br-lan carries no IP
# of its own; relayd anchors on the STA's DHCP lease, so nothing is hand-picked and nothing can collide with
# the upstream pool. The upstream gateway is .1 of the lease's subnet. Inert in
# ap/wired/wds mode (no 'wwan' iface). Not shipped in a proxy build: pstad
# replaces relayd there, and the two must not both be running.
if [ "$BACKHAUL" != proxy ]; then
	cat > "$FILES/etc/hotplug.d/iface/99-relayd" <<'HOTPLUG'
#!/bin/sh
[ "$ACTION" = ifup ] && [ "$INTERFACE" = wwan ] || exit 0
STA=$(ubus call network.interface.wwan status 2>/dev/null | jsonfilter -e '@.l3_device')
LEASE=$(ubus call network.interface.wwan status 2>/dev/null | jsonfilter -e '@["ipv4-address"][0].address')
[ -n "$STA" ] && [ -n "$LEASE" ] || exit 0
GW="${LEASE%.*}.1"
kill "$(pgrep -x relayd)" 2>/dev/null
relayd -I br-lan -I "$STA" -G "$GW" -L "$LEASE" -D -B >/dev/null 2>&1 &
HOTPLUG
	chmod +x "$FILES/etc/hotplug.d/iface/99-relayd"
fi

# proxy backhaul: ship the proxy-STA daemon instead of relayd, so each client
# keeps its own MAC upstream. Allowlist wide open (image-side; access control
# is the upstream network's job); the service symlink enables it at first boot.
# psta/ is the openwrt-pstad submodule: git submodule update --init
if [ "$BACKHAUL" = proxy ]; then
	cp "$SRCDIR/psta/pstad" "$FILES/usr/sbin/pstad"
	cp "$SRCDIR/psta/pstad.init" "$FILES/etc/init.d/pstad"
	chmod +x "$FILES/usr/sbin/pstad" "$FILES/etc/init.d/pstad"
	echo '*' > "$FILES/etc/psta/allow"
	mkdir -p "$FILES/etc/rc.d"
	ln -sf ../init.d/pstad "$FILES/etc/rc.d/S99pstad"
fi

# SSH access: the script's own ephemeral key (for key-based verify) plus any keys
# supplied in creds.json, baked into root's dropbear authorized_keys.
[ -f "$AUTOKEY" ] || ssh-keygen -q -t ed25519 -N '' -C flash-wr1800k -f "$AUTOKEY"
{ cat "$AUTOKEY.pub"; [ -n "$SSH_KEYS" ] && printf '%s\n' "$SSH_KEYS"; } > "$FILES/etc/dropbear/authorized_keys"
chmod 600 "$FILES/etc/dropbear/authorized_keys"

# proxy ships pstad instead of relayd, plus tc/bridge tooling the daemon shells
# out to for per-client MAC handling and tcpdump for its roam monitor; every
# other backhaul keeps relayd.
if [ "$BACKHAUL" = proxy ]; then
	PACKAGES="umdns luci tc-full kmod-sched-core kmod-sched-flower ip-bridge tcpdump-mini"
else
	PACKAGES="umdns relayd luci"
fi
( cd "$IB_NAME" && make image PROFILE="$PROFILE" FILES="$FILES" PACKAGES="$PACKAGES" )

SYSUP=$(ls "$IB_NAME"/bin/targets/ramips/mt7621/*sim_simax1800t-squashfs-sysupgrade.bin 2>/dev/null | head -1)
[ -n "$SYSUP" ] && [ -f "$SYSUP" ] || die "sysupgrade image not produced"
echo "built: $SYSUP"
[ "$BUILD_ONLY" = 1 ] && exit 0

INITRAMFS="$WORK/initramfs.bin"
[ -f "$INITRAMFS" ] || curl -fL -o "$INITRAMFS" \
	"$DL/openwrt-${VER}-ramips-mt7621-sim_simax1800t-initramfs-kernel.bin"
cp "$INITRAMFS" "$TFTPROOT/factory.bin"

# =====================================================================
msg "2/5  arm host networking + TFTP on $IFACE ($HOST_RECOVERY_IP)"
# The router's LAN is 192.168.1.1, which usually collides with the host's own
# LAN, and a managed host will strip or block our static setup. Handle all three
# (all reverted in cleanup):
#  - take the NIC out of NetworkManager so it can't flush our address
if command -v nmcli >/dev/null 2>&1 && nmcli -t -f DEVICE dev 2>/dev/null | grep -qx "$IFACE"; then
	$SUDO nmcli device set "$IFACE" managed no 2>/dev/null && NM_UNMANAGED=1 || true
fi
# /32, not /24: a /24 here would add a connected 192.168.1.0/24 route on the wired
# NIC that steals every 192.168.1.x host (e.g. an SSH-reachable smart-plug host used
# for power_off_cmd) away from Wi-Fi. The explicit /32 routes below carry the only
# addresses network-boot needs.
$SUDO ip addr add "$HOST_RECOVERY_IP/32" dev "$IFACE" 2>/dev/null || true
$SUDO ip link set "$IFACE" up
#  - a /32 route pins the device address to the wired NIC (more specific than any
#    existing 192.168.1.0/24 on another interface), so we always reach the router
$SUDO ip route replace "$DEVICE_IP/32" dev "$IFACE"
#    U-Boot uses 192.168.1.222 during factory-boot TFTP; without this route the
#    tftpd reply goes out Wi-Fi (same /24) and the transfer silently never starts
$SUDO ip route replace "$UBOOT_IP/32" dev "$IFACE"
#  - let the bootloader's TFTP read request through a restrictive host firewall.
#    Only port 69 is needed: the firmware push and the nc probes are all
#    host-initiated, so their replies ride the host's existing ESTABLISHED rule.
#    Accepting everything on $IFACE would expose the host to the whole segment
#    whenever the wire is not the isolated link this flow asks for.
if command -v iptables >/dev/null 2>&1; then
	$SUDO iptables -I INPUT -i "$IFACE" -p udp --dport 69 -j ACCEPT 2>/dev/null && FW_ADDED=1 || true
fi
# -u: tftpd drops to 'nobody' by default, which cannot traverse a 0700 home
# directory. U-Boot reports that as "TFTP error: 'Permission denied'".
$SUDO in.tftpd -L -u "$(id -un)" -a "$HOST_RECOVERY_IP:69" -s "$TFTPROOT" &
TFTPD_PID=$!
sleep 1; $SUDO kill -0 "$TFTPD_PID" 2>/dev/null || die "tftpd failed to start"

# =====================================================================
msg "3/5  network-boot the stock initramfs"
# The factory-boot TFTP window is short; if the wired link hasn't re-negotiated
# in time the router boots NAND instead. Blank-password root SSH works only on
# the stock initramfs, so use it to tell the two apart and, on a NAND boot, ask
# for another power-cycle rather than failing.
init_ssh() { sshpass -p '' ssh $SSH_OPTS -o PreferredAuthentications=password -o PubkeyAuthentication=no root@"$DEVICE_IP" "$@"; }
power_cycle() {
	if [ -n "$POWER_OFF_CMD" ] && [ -n "$POWER_ON_CMD" ]; then
		echo ">>> power-cycling the router (attempt $try) via configured commands <<<"
		eval "$POWER_OFF_CMD" >/dev/null 2>&1 || echo "  (power-off command failed)"
		sleep 4
		eval "$POWER_ON_CMD"  >/dev/null 2>&1 || echo "  (power-on command failed)"
	else
		echo ">>> POWER-CYCLE THE ROUTER NOW (unplug/replug power), attempt $try <<<"
	fi
}
# Discover the per-unit U-Boot factory-boot IP and pin a /32 route so tftpd's
# replies egress the wired NIC. The IP varies per unit (.222, .217, ...); U-Boot
# TFTP-reads factory.bin from our server ($HOST_RECOVERY_IP) and retries every
# ~5s for many rounds, so routing it mid-retry completes the transfer without
# knowing it ahead of time. Key off the RRQ's source, not ARP: the read request
# for factory.bin is the only packet whose source is unambiguously the U-Boot.
# A unit being reflashed still runs its old relayd (and the upstream) which
# proxy-ARPs our recovery address. "who-has .254 tell .1" would otherwise be
# mistaken for the router.
uboot_discover() {
	local pkt ip
	pkt=$($SUDO timeout 150 tcpdump -ni "$IFACE" -l -c1 \
		"dst host $HOST_RECOVERY_IP and udp dst port 69" 2>/dev/null)
	ip=$(printf '%s\n' "$pkt" | grep -oE "([0-9]+\.){4}[0-9]+ >" | sed -E 's/\.[0-9]+ >$//')
	if [ -n "$ip" ] && [ "$ip" != "$HOST_RECOVERY_IP" ]; then
		$SUDO ip route replace "$ip/32" dev "$IFACE"
		echo ">>> discovered U-Boot IP $ip, pinned /32 route <<<"
	fi
}
uboot_discover &
got_initramfs=0
for try in $(seq 1 6); do
	power_cycle
	# wait for :22 to drop (reboot starts) then to come back
	for _ in $(seq 1 25); do nc -z -w1 "$DEVICE_IP" 22 2>/dev/null || break; sleep 1; done
	up=0; for _ in $(seq 1 90); do nc -z -w1 "$DEVICE_IP" 22 2>/dev/null && { up=1; break; }; sleep 2; done
	[ "$up" = 1 ] || { echo "no SSH yet, retrying..."; continue; }
	if init_ssh true 2>/dev/null; then
		echo "stock initramfs is up."
		got_initramfs=1; break
	fi
	echo "that boot was the on-flash image (TFTP missed the window). Power-cycle again."
done
[ "$got_initramfs" = 1 ] || die "initramfs never network-booted after 6 tries; check wired-link timing / serial"

# =====================================================================
msg "4/5  push sysupgrade and flash NAND"
# the stock initramfs has no sftp-server, so stream the image over ssh via cat
init_ssh 'cat > /tmp/fw.bin' < "$SYSUP"
want=$(wc -c < "$SYSUP"); got=$(init_ssh 'wc -c < /tmp/fw.bin' 2>/dev/null)
[ "$want" = "$got" ] || die "sysupgrade transfer incomplete ($got/$want bytes)"
echo "transferred $got bytes"
# stop serving factory.bin so the post-flash reboot falls through to NAND
$SUDO pkill -f "in.tftpd.*$TFTPROOT" 2>/dev/null || true; TFTPD_PID=""
# run detached in a new session, else sysupgrade kills its own SSH session before
# handing off to stage 2 (ubus "Connection failed") and never flashes
init_ssh 'setsid sysupgrade -n /tmp/fw.bin </dev/null >/tmp/su.log 2>&1 &' || true

# =====================================================================
msg "5/5  wait for NAND boot and verify"
if [ "$MODE" = ap ]; then
	# ap mode: the device comes up on $LAN_IPADDR, reachable over the wire.
	VERIFY_IP="$LAN_IPADDR"
	if [ "$VERIFY_IP" != "$DEVICE_IP" ]; then
		$SUDO ip addr add "${LAN_IPADDR%.*}.254/24" dev "$IFACE" 2>/dev/null && VHOST_ADDED=1 || true
	fi
	sleep 30
	up=0
	for _ in $(seq 1 90); do
		if nc -z -w1 "$VERIFY_IP" 22 2>/dev/null; then up=1; break; fi
		sleep 2
	done
	[ "$up" = 1 ] || die "device did not return on SSH after flash (check serial)"

	# verify with the script's baked key (works whether or not a root password was set)
	sshx() { ssh -i "$AUTOKEY" $SSH_OPTS root@"$VERIFY_IP" "$@"; }
	sshx true 2>/dev/null || die "SSH up but key auth fails, flash may not have applied (device likely on the previous image; check serial)"
	REL=$(sshx '. /etc/openwrt_release; echo "$DISTRIB_RELEASE-$DISTRIB_REVISION"')
	OVL=$(sshx 'mount | grep -q "on / type overlay" && mount | grep -q ubifs && echo ubifs-overlay || echo NO-OVERLAY')
	HN=$(sshx 'uci -q get system.@system[0].hostname')
	MAC=$(sshx 'cat /sys/class/net/eth0/address')
	WIFI=$(sshx 'iwinfo 2>/dev/null | grep -c ESSID || echo 0')
	UMD=$(sshx 'pgrep -x umdns >/dev/null && echo running || echo not-running')
	PWSET=$(sshx 'grep -q "^root:[^:]" /etc/shadow && echo yes || echo no')

	msg "RESULT"
	printf 'mode:             ap (standalone router)\n'
	printf 'OpenWrt:          %s\n' "$REL"
	printf 'overlay:          %s\n' "$OVL"
	printf 'hostname:         %s\n' "$HN"
	printf 'MAC:              %s\n' "$MAC"
	printf 'Wi-Fi ifaces up:  %s\n' "$WIFI"
	printf 'umdns:            %s\n' "$UMD"
	printf 'root password set:%s   (SSH key auth: yes)\n' "$PWSET"
	printf 'address (bench):  %s\n' "$VERIFY_IP"
	printf 'mDNS name:        %s.local   (after deployment: ssh root@%s.local)\n' "$HN" "$HN"
	if command -v avahi-resolve >/dev/null 2>&1; then
		avahi-resolve -n "$HN.local" 2>/dev/null \
			&& echo "(mDNS resolves on this link)" \
			|| echo "(mDNS name not resolvable from here, needs avahi on host + same L2)"
	fi
else
	# bridge/repeater: the device joins the upstream network by DHCP and bridges
	# the wired port onto it, so it is not reachable on the isolated recovery wire.
	# Give it time to boot, then point the user at it on the main LAN.
	sleep 45
	msg "RESULT"
	printf 'mode:     %s (backhaul: %s)\n' "$MODE" "$BACKHAUL"
	printf 'flash:    sysupgrade written; device rebooted\n'
	case "$BACKHAUL" in
	wired) printf 'backhaul: wired. Plug the uplink into a LAN port\n' ;;
	proxy) printf 'backhaul: joins "%s" over Wi-Fi (proxy STA), rebroadcasts "%s"\n' "$MAIN_SSID" "$WIFI_SSID" ;;
	*)     printf 'backhaul: joins "%s" over Wi-Fi (%s), rebroadcasts "%s"\n' "$MAIN_SSID" "$BACKHAUL" "$WIFI_SSID" ;;
	esac
	printf 'clients:  lease from the upstream router; every device gets an upstream-subnet address\n'
	case "$BACKHAUL" in
	relayd) printf 'find it:  ssh root@%s-<last 3 MAC bytes>. The upstream router resolves the\n' "$PREFIX"
	        printf '          hostname to the STA lease (no static mgmt IP); LuCI answers there too\n' ;;
	proxy)  printf 'find it:  %s-<last 3 MAC bytes>.local via mDNS on the "%s" network. Proxy STA gives\n' "$PREFIX" "$MAIN_SSID"
	        printf '          each client its own MAC upstream, so mDNS resolves everywhere (unlike relayd)\n' ;;
	*)      printf 'find it:  %s-<last 3 MAC bytes>.local via mDNS on the "%s" network\n' "$PREFIX" "$MAIN_SSID" ;;
	esac
	printf 'note:     not verifiable over the isolated recovery wire in this mode;\n'
	printf '          check the upstream router'"'"'s client list.\n'
fi
