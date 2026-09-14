#!/bin/sh
# First-boot provisioning for the WR1800K OpenWrt image.
#
# The flasher prepends a block of shell variable assignments (baked from
# creds.json) above this script, then installs the whole thing as
# /etc/uci-defaults/99-provision, which runs once on first boot and is then
# removed by OpenWrt. The prepended variables are:
#
#   MODE           ap | bridge
#   BACKHAUL       bridge-mode uplink: relayd | wds | wired | proxy
#   ROOT_HASH      sha-512 crypt of the root password, or "" (SSH-key only)
#   PREFIX         hostname/mDNS prefix
#   UPSTREAM_SSID  network to JOIN  (repeater backhaul)
#   AP_SSID        network to BROADCAST (ap_ssid, else main_ssid)
#   ENC            wifi encryption (e.g. sae-mixed)
#   KEY            wifi PSK
#   COUNTRY        regulatory domain
#   LAN_IPADDR     LAN address in ap mode (non-overlapping bench subnet)
#   BACKHAUL_BAND  2 or 5 (GHz) radio to use for the repeater backhaul
#
# Modes:
#   ap                 standalone router on LAN_IPADDR with its own DHCP (bench default)
#   bridge             extender; clients land on the upstream subnet. BACKHAUL picks the uplink:
#     backhaul=wired     Ethernet/coax uplink into a LAN port; true L2 dumb AP (most reliable)
#     backhaul=relayd    3-address STA + relayd proxy-ARP/DHCP-relay; works with any AP (e.g. Verizon Fios)
#     backhaul=wds       4-address WDS STA bridged into the LAN; needs a WDS-capable upstream
#     backhaul=proxy     per-client proxy STA (pstad); drops relayd, each client keeps its own MAC upstream

# --- root password (optional) ---
[ -n "$ROOT_HASH" ] && sed -i "s#^root:[^:]*:#root:$ROOT_HASH:#" /etc/shadow

# --- hostname / mDNS name: <prefix>-<last 3 MAC bytes> ---
MAC=$(tr -d ':' < /sys/class/net/eth0/address)
MACSUF=$(printf '%s' "$MAC" | tail -c 6)
uci set system.@system[0].hostname="${PREFIX}-${MACSUF}"
uci commit system

# AP_SSID may carry a {mac} token, expanded here to this unit's MAC suffix so a
# prefix like "WR1800K-test-{mac}" yields a unique per-unit SSID (as the hostname
# does); a plain string such as "MyNetwork" is used as-is.
AP_SSID=$(printf '%s' "$AP_SSID" | sed "s/{mac}/${MACSUF}/g")

# --- radios: regulatory country, enabled ---
RADIOS=$(uci show wireless | sed -n "s/^wireless\.\(radio[0-9]*\)=wifi-device/\1/p")
for dev in $RADIOS; do
	uci set wireless.$dev.country="$COUNTRY"
	uci set wireless.$dev.disabled='0'
done

# radio carrying the wireless backhaul (repeater), chosen by band
BH_BAND=2g; [ "$BACKHAUL_BAND" = 5 ] && BH_BAND=5g
BH_RADIO=
for dev in $RADIOS; do
	[ "$(uci -q get wireless.$dev.band)" = "$BH_BAND" ] && BH_RADIO=$dev
done

AP_IFACES=$(uci show wireless | sed -n "s/^wireless\.\(default_radio[0-9]*\)=wifi-iface/\1/p")

# rebroadcast AP on the non-backhaul radio only; the backhaul radio's own AP off
set_repeater_aps() {
	for ifc in $AP_IFACES; do
		if [ "$(uci -q get wireless.$ifc.device)" = "$BH_RADIO" ]; then
			uci set wireless.$ifc.disabled='1'
		else
			uci set wireless.$ifc.ssid="$AP_SSID"; uci set wireless.$ifc.encryption="$ENC"
			uci set wireless.$ifc.key="$KEY"; uci set wireless.$ifc.network='lan'
		fi
	done
}
# AP on every radio, bridged to lan
set_all_aps() {
	for ifc in $AP_IFACES; do
		uci set wireless.$ifc.ssid="$AP_SSID"; uci set wireless.$ifc.encryption="$ENC"
		uci set wireless.$ifc.key="$KEY"; uci set wireless.$ifc.network='lan'
	done
}
# LAN joins the upstream subnet as a DHCP client, no local DHCP server
set_lan_upstream_dhcp() {
	uci set network.lan.proto='dhcp'
	uci -q delete network.lan.ipaddr; uci -q delete network.lan.netmask; uci -q delete network.lan.gateway
	uci set dhcp.lan.ignore='1'
}

# 3-address STA on its own wwan interface, upstream reached at L3 through
# whatever bridges wwan to lan: relayd's proxy-ARP/DHCP-relay, or per-client
# proxy STA (pstad). Shared by the relayd and proxy backhauls so the two
# cannot drift apart.
set_station_and_aps() {
	uci set network.lan.proto='none'
	uci -q delete network.lan.ipaddr
	uci -q delete network.lan.netmask
	uci -q delete network.lan.gateway
	uci set dhcp.lan.ignore='1'
	uci set network.wwan='interface'; uci set network.wwan.proto='dhcp'
	uci set wireless.wwan='wifi-iface'
	uci set wireless.wwan.device="$BH_RADIO"; uci set wireless.wwan.mode='sta'
	uci set wireless.wwan.network='wwan'
	uci set wireless.wwan.ssid="$UPSTREAM_SSID"; uci set wireless.wwan.encryption="$ENC"; uci set wireless.wwan.key="$KEY"
	# trust the STA interface (lan zone) so relayed/proxied traffic is not firewalled
	uci set firewall.@zone[0].network='lan wwan'
	set_repeater_aps
}

if [ "$MODE" = bridge ]; then
	# extender onto the upstream subnet; BACKHAUL selects the uplink
	case "$BACKHAUL" in
	wired)
		# Ethernet/coax uplink into a LAN port: true L2 dumb AP, clients on the
		# upstream subnet. Most reliable where a wire reaches.
		set_lan_upstream_dhcp
		set_all_aps
		;;
	wds)
		# WDS (4-address) wireless backhaul: STA bridged straight into br-lan.
		# Requires the upstream AP to accept 4-address frames (many ISP routers,
		# Verizon Fios included, do NOT; use relayd there).
		set_lan_upstream_dhcp
		uci set wireless.wwan='wifi-iface'
		uci set wireless.wwan.device="$BH_RADIO"; uci set wireless.wwan.mode='sta'
		uci set wireless.wwan.network='lan'; uci set wireless.wwan.wds='1'
		uci set wireless.wwan.ssid="$UPSTREAM_SSID"; uci set wireless.wwan.encryption="$ENC"; uci set wireless.wwan.key="$KEY"
		set_repeater_aps
		;;
	proxy)
		# per-client proxy STA (pstad) wireless backhaul: same station/AP/firewall
		# setup as relayd, but each client keeps its own MAC upstream instead of
		# sharing the STA's. The image ships no relayd hotplug and symlinks pstad's
		# init script on at first boot (see flash-wr1800k.sh); this enable is
		# defensive/idempotent in case that symlink is ever missing.
		set_station_and_aps
		/etc/init.d/pstad enable 2>/dev/null
		;;
	*)
		# relayd (default) wireless backhaul: a plain 3-address STA on its own wwan
		# interface plus relayd proxy-ARP/DHCP-relay. Works with any upstream AP
		# (Verizon Fios, for example). br-lan takes no IP of its own and runs no DHCP; relayd
		# (launched by /etc/hotplug.d/iface/99-relayd when wwan is up) bridges it to
		# the STA at L3 and anchors on the STA's DHCP lease. Manage the repeater
		# through that lease, resolvable by hostname on the upstream router.
		set_station_and_aps
		;;
	esac
else
	# ap (default): standalone router on a non-overlapping LAN with its own DHCP
	uci set network.lan.proto='static'
	uci set network.lan.ipaddr="$LAN_IPADDR"
	uci set network.lan.netmask='255.255.255.0'
	set_all_aps
fi

uci commit
exit 0
