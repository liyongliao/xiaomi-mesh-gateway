#!/bin/sh
set -eu
BASE=/userdisk/mesh-gateway
rule() {
    iptables -C INPUT -i br-lan -p udp --sport 68 --dport 67 -m comment --comment mesh-gateway-dhcp -j NFQUEUE --queue-num 3131 --queue-bypass 2>/dev/null ||
    iptables -I INPUT 1 -i br-lan -p udp --sport 68 --dport 67 -m comment --comment mesh-gateway-dhcp -j NFQUEUE --queue-num 3131 --queue-bypass
}
apply() {
    lua "$BASE/manage.lua" prepare
    sed 's|/tmp/mesh-gateway-options$|/tmp/mesh-gateway-options.new|' "$BASE/dnsmasq.conf" > /tmp/mesh-gateway-dnsmasq-test.conf
    dnsmasq --test --conf-file=/tmp/mesh-gateway-dnsmasq-test.conf
    mv /tmp/mesh-gateway-options.new /tmp/mesh-gateway-options
    if ! grep -Fq "conf-file=$BASE/dnsmasq.conf" /etc/dnsmasq.conf; then
        printf '\n# Mesh gateway plugin\nconf-file=%s/dnsmasq.conf\n' "$BASE" >> /etc/dnsmasq.conf
        /etc/init.d/dnsmasq restart
    else
        killall -HUP dnsmasq
    fi
    if ! cmp -s /tmp/mesh-gateway-roam.new /etc/roam.conf; then
        cp /tmp/mesh-gateway-roam.new /etc/roam.conf
        /etc/init.d/miwifi-roam restart
    fi
}
case "${1:-}" in
  apply) apply ;;
  firewall) [ ! -f /tmp/mesh-gateway-disabled ] && rule ;;
  start)
    [ -f /tmp/mesh-gateway-disabled ] && exit 0
    [ "$(uci -q -c /usr/share/xiaoqiang get xiaoqiang_version.version.ROM)" = "1.1.56" ] || { echo 'Unsupported firmware'; exit 1; }
    cp "$BASE/service-init" /etc/init.d/mesh-gateway
    chmod 755 /etc/init.d/mesh-gateway
    apply
    /etc/init.d/mesh-gateway start
    for i in 1 2 3 4 5 6 7 8 9 10; do [ -f /tmp/mesh-gateway-queue.ready ] && break; sleep 1; done
    [ -f /tmp/mesh-gateway-queue.ready ] || { echo 'Queue did not start'; exit 1; }
    rule
    if ! mount | grep -q 'on /usr/lib/lua/luci/controller '; then
        mkdir -p /tmp/mesh-gateway-controller
        cp -a /usr/lib/lua/luci/controller/. /tmp/mesh-gateway-controller/
        ln -sf "$BASE/mesh_gateway.lua" /tmp/mesh-gateway-controller/mesh_gateway.lua
        mount -o bind /tmp/mesh-gateway-controller /usr/lib/lua/luci/controller
    fi
    if ! mount | grep -q 'on /usr/lib/lua/luci/view/web/inc/header.htm '; then
        lua "$BASE/manage.lua" header
        mount -o bind /tmp/mesh-gateway-header.htm /usr/lib/lua/luci/view/web/inc/header.htm
    fi
    rm -f /tmp/luci-indexcache
    ;;
  stop)
    touch /tmp/mesh-gateway-disabled
    uci -q delete firewall.mesh_gateway || true
    uci commit firewall
    while iptables -C INPUT -i br-lan -p udp --sport 68 --dport 67 -m comment --comment mesh-gateway-dhcp -j NFQUEUE --queue-num 3131 --queue-bypass 2>/dev/null; do
        iptables -D INPUT -i br-lan -p udp --sport 68 --dport 67 -m comment --comment mesh-gateway-dhcp -j NFQUEUE --queue-num 3131 --queue-bypass
    done
    /etc/init.d/mesh-gateway stop || true
    sed -i '\|conf-file=/userdisk/mesh-gateway/dnsmasq.conf|d' /etc/dnsmasq.conf
    /etc/init.d/dnsmasq restart
    cp "$BASE/backup/roam.conf" /etc/roam.conf
    /etc/init.d/miwifi-roam restart
    umount /usr/lib/lua/luci/view/web/inc/header.htm || true
    umount /usr/lib/lua/luci/controller || true
    rm -f /tmp/luci-indexcache /tmp/mesh-gateway-queue.ready
    ;;
  *) echo 'Usage: service.sh start|apply|firewall|stop'; exit 1 ;;
esac
