#!/bin/sh
set -eu
BASE=/userdisk/mesh-gateway
URL=https://github.com/liyongliao/xiaomi-mesh-gateway/releases/download/v1.0.1/xiaomi-mesh-gateway-linux-arm64.tar.gz
EXPECTED=5704852ba3f5efa303104745251ff470d7c71d95d1275237482ce6fa86b77135
[ "$(id -u)" = 0 ] || { echo '请以 root 身份运行'; exit 1; }
command -v uci >/dev/null || { echo '未找到 uci：请在路由器上运行'; exit 1; }
[ "$(uci -q -c /usr/share/xiaoqiang get xiaoqiang_version.version.HARDWARE)" = RC01 ] || { echo '不支持的路由器型号'; exit 1; }
[ "$(uci -q -c /usr/share/xiaoqiang get xiaoqiang_version.version.ROM)" = 1.1.56 ] || { echo '仅支持固件 1.1.56'; exit 1; }
[ "$(uci -q get network.lan.ipaddr)" = 192.168.31.1 ] || { echo '目前仅支持 LAN 地址为 192.168.31.1'; exit 1; }
[ ! -e /tmp/mesh-gateway-disabled ] || { echo "本次启动中插件已停止，请重启路由器后安装"; exit 1; }
[ ! -e "$BASE" ] || { echo '已有安装目录：为保护现有配置，安装已停止'; exit 1; }
command -v sha256sum >/dev/null || { echo '缺少 sha256sum'; exit 1; }
command -v curl >/dev/null || { echo '缺少 curl'; exit 1; }
WORK=$(mktemp -d /tmp/mesh-gateway-install.XXXXXX)
started=0
cleanup() {
  code=$?
  trap - EXIT
  if [ "$code" -ne 0 ] && [ "$started" = 1 ]; then
    echo '安装失败，正在恢复原有路由器设置' >&2
    "$BASE/service.sh" stop || true
  fi
  rm -rf "$WORK"
  exit "$code"
}
trap cleanup EXIT
curl -fL --connect-timeout 15 --max-time 180 "$URL" -o "$WORK/package.tar.gz"
ACTUAL=$(sha256sum "$WORK/package.tar.gz" | awk '{print $1}')
[ "$ACTUAL" = "$EXPECTED" ] || { echo '安装包校验失败'; exit 1; }
mkdir -p "$WORK/files"
tar -xzf "$WORK/package.tar.gz" -C "$WORK/files"
for f in mesh-gateway boot.sh service.sh service-init config.json dnsmasq.conf manage.lua mesh_gateway.lua index.html; do
  [ -f "$WORK/files/$f" ] || { echo "安装包缺少 $f"; exit 1; }
done
mkdir -m 700 "$BASE"
cp -R "$WORK/files/." "$BASE/"
chmod 755 "$BASE/mesh-gateway" "$BASE/boot.sh" "$BASE/service.sh" "$BASE/service-init"
chmod 600 "$BASE/config.json"
mkdir -m 700 "$BASE/backup"
cp -p /etc/roam.conf "$BASE/backup/roam.conf"
started=1
"$BASE/service.sh" start
uci set firewall.mesh_gateway=include
uci set firewall.mesh_gateway.type=script
uci set firewall.mesh_gateway.path=/userdisk/mesh-gateway/boot.sh
uci set firewall.mesh_gateway.enabled=1
uci set firewall.mesh_gateway.reload=1
uci commit firewall
started=0
echo '安装完成：登录小米路由器后台，点击右下角「Mesh 与 Wi-Fi 分流」。'
echo '默认关闭分流和漫游调整，请在页面中配置并启用。'
