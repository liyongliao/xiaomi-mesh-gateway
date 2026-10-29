# Xiaomi Mesh Gateway

小米万兆路由器 RC01、原厂固件 1.1.56 的本地扩展：按 Wi-Fi 下发 IPv4 网关和 DNS，调整主路由 Mesh 漫游候选参数。其他机型和固件未经验证。

## 安装

编译 ARM64 程序：

```sh
go test ./src
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -trimpath -ldflags='-s -w' -o plugin/mesh-gateway ./src
```

将 `plugin/` 内容复制到路由器 `/userdisk/mesh-gateway/`，然后以 root 执行：

```sh
chmod 700 /userdisk/mesh-gateway
chmod 755 /userdisk/mesh-gateway/mesh-gateway /userdisk/mesh-gateway/boot.sh /userdisk/mesh-gateway/service.sh /userdisk/mesh-gateway/service-init
chmod 600 /userdisk/mesh-gateway/config.json
mkdir -p /userdisk/mesh-gateway/backup
chmod 700 /userdisk/mesh-gateway/backup
cp -p /etc/roam.conf /userdisk/mesh-gateway/backup/roam.conf
/userdisk/mesh-gateway/service.sh start
uci set firewall.mesh_gateway=include
uci set firewall.mesh_gateway.type=script
uci set firewall.mesh_gateway.path=/userdisk/mesh-gateway/boot.sh
uci set firewall.mesh_gateway.enabled=1
uci set firewall.mesh_gateway.reload=1
uci commit firewall
```

登录小米后台，点击右下角「Mesh 与 Wi-Fi 分流」。默认关闭分流和漫游调整；设置网关、DNS 后启用。网关目前限制在 192.168.31.0/24；确认网关实际可访问，客户端重新获取 DHCP 租约后生效。IPv6、手动配置和加密 DNS 不受此功能控制。

## Mesh 子节点

默认不识别子节点。核对子节点 MAC、SSID 和无线接口后，在路由器 `/userdisk/mesh-gateway/config.json` 的 `mesh_nodes` 中填写映射，例如 `"02:00:00:00:00:01":{"wl0":"wl0","wl1":"wl1"}`，然后执行 `/etc/init.d/mesh-gateway restart`。示例 MAC 必须替换。子节点关联信息未同步时 DHCP 使用默认设置，同步后需重新获取租约。漫游参数只修改主路由，实际切换取决于终端和同名网络覆盖。

## 实现和恢复

通过 NFQUEUE 为 DHCP 请求添加标签，由原生 dnsmasq 分配地址及网关、DNS；进程不可用时采用 DHCP 默认配置。网页沿用小米后台登录。防火墙 include 负责恢复启动，固件升级及重启兼容性需自行验证。

执行 `/userdisk/mesh-gateway/service.sh stop` 可移除扩展的队列规则和启动配置，并恢复备份的漫游参数；客户端需重新获取租约。
