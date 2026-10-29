#!/bin/sh
BASE=/userdisk/mesh-gateway
[ -f /tmp/mesh-gateway-disabled ] && exit 0
if [ -f /tmp/mesh-gateway-queue.ready ] && grep -q '3131 ' /proc/net/netfilter/nfnetlink_queue 2>/dev/null; then
    "$BASE/service.sh" firewall
    exit 0
fi
mkdir /tmp/mesh-gateway-boot.lock 2>/dev/null || exit 0
(
    trap 'rmdir /tmp/mesh-gateway-boot.lock 2>/dev/null' EXIT
    for i in $(seq 1 90); do
        if [ -d /sys/class/net/br-lan ] && [ -S /var/run/hostapd-wifi1/wl0 ]; then
            "$BASE/service.sh" start
            exit $?
        fi
        sleep 2
    done
    echo 'Mesh gateway: LAN/Wi-Fi did not become ready'
) > /tmp/mesh-gateway-boot.log 2>&1 </dev/null &
exit 0
