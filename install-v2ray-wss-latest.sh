
#!/usr/bin/env bash
# V2Ray + Caddy 最新稳定版安装器
# 系统：Debian 12
# 功能：VLESS/VMess、WebSocket + TLS、Caddy 反向代理、BBR、UUID/链接/二维码、备份和配置验证
# 注意：不自动安装第三方 WARP 脚本

set -Eeuo pipefail
umask 077

readonly V2RAY_INSTALLER="https://raw.githubusercontent.com/v2fly/fhs-install-v2ray/master/install-release.sh"
readonly GEO_INSTALLER="https://raw.githubusercontent.com/v2fly/fhs-install-v2ray/master/install-dat-release.sh"
readonly CADDY_KEY="https://dl.cloudsmith.io/public/caddy/stable/gpg.key"
readonly CADDY_REPO="https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt"
readonly V2RAY_CONFIG="/usr/local/etc/v2ray/config.json"
readonly CADDYFILE="/etc/caddy/Caddyfile"

die() {
    echo "错误：$*" >&2
    exit 1
}

info() {
    echo
    echo "========== $* =========="
}

warn() {
    echo "警告：$*" >&2
}

[[ "$EUID" -eq 0 ]] || die "请使用 root 运行。"
[[ -r /etc/os-release ]] || die "无法读取系统信息。"
. /etc/os-release
[[ "${ID:-}" == "debian" && "${VERSION_ID:-}" == "12" ]] ||
    die "此脚本仅针对 Debian 12。"

echo "V2Ray + Caddy 最新稳定版安装器"
echo "安装前会备份现有配置，并检查新配置。"
echo "不会自动执行第三方 WARP 安装脚本。"
echo

read -r -p "请输入你的域名，例如 example.com: " DOMAIN
DOMAIN="${DOMAIN,,}"

[[ "$DOMAIN" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]] ||
    die "域名格式无效。"

read -r -p "网络类型 [4=IPv4，6=IPv6，auto=自动判断，默认 auto]: " NETSTACK
NETSTACK="${NETSTACK:-auto}"
[[ "$NETSTACK" == "4" || "$NETSTACK" == "6" || "$NETSTACK" == "auto" ]] ||
    die "网络类型只能是 4、6 或 auto。"

read -r -p "协议 [V=VLESS，M=VMess，默认 V]: " PROTOCOL_INPUT
case "${PROTOCOL_INPUT:-V}" in
    V|v) PROTOCOL="vless" ;;
    M|m) PROTOCOL="vmess" ;;
    *) die "协议选项无效。" ;;
esac

UUID="$(cat /proc/sys/kernel/random/uuid)"
read -r -p "UUID（直接回车使用随机 UUID）: " UUID_INPUT
[[ -n "${UUID_INPUT:-}" ]] && UUID="$UUID_INPUT"

[[ "$UUID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] ||
    die "UUID 格式无效。"

DEFAULT_PATH="${UUID:24:12}"
read -r -p "WebSocket path（不含斜杠，默认 ${DEFAULT_PATH}）: " PATH_INPUT
WS_PATH="${PATH_INPUT:-$DEFAULT_PATH}"

[[ "$WS_PATH" =~ ^[A-Za-z0-9._~-]{1,100}$ ]] ||
    die "path 只能包含字母、数字、点、下划线、波浪线和连字符。"

DEFAULT_CAMO="https://www.wikipedia.org"
read -r -p "伪装网站根 URL（默认 ${DEFAULT_CAMO}）: " CAMO_INPUT
CAMO="${CAMO_INPUT:-$DEFAULT_CAMO}"

[[ "$CAMO" =~ ^https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?/?$ ]] ||
    die "伪装 URL 格式无效，请输入类似 https://www.wikipedia.org 的根 URL。"

V2RAY_PORT="$(shuf -i 20001-60000 -n 1)"

echo
echo "安装参数："
echo "域名：$DOMAIN"
echo "网络类型：$NETSTACK"
echo "协议：$PROTOCOL"
echo "UUID：$UUID"
echo "WebSocket path：/$WS_PATH"
echo "内部端口：$V2RAY_PORT"
echo "伪装站点：$CAMO"
echo "外部端口：TCP 443；证书申请还需要 TCP 80 可访问。"
echo
warn "请确保域名已解析到本机，且 Cloudflare DNS 记录暂时使用 DNS only（灰云）。"
warn "安装会更新程序并替换 V2Ray、Caddy 主配置文件；旧文件会先备份。"
read -r -p "确认继续？请输入 YES: " CONFIRM
[[ "$CONFIRM" == "YES" ]] || die "已取消。"

info "安装系统依赖"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y \
    ca-certificates curl gnupg jq qrencode dnsutils \
    iproute2 procps debian-keyring debian-archive-keyring \
    apt-transport-https

info "检查域名解析"
echo "A 记录："
dig +short A "$DOMAIN" || true
echo "AAAA 记录："
dig +short AAAA "$DOMAIN" || true
warn "请核对解析结果与服务器公网地址是否一致。"

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/v2ray-wss-backup-${STAMP}"
mkdir -m 0700 -p "$BACKUP"

info "备份现有文件"
for FILE in \
    /usr/local/etc/v2ray \
    /usr/local/bin/v2ray \
    /usr/local/bin/v2ctl \
    /etc/systemd/system/v2ray.service \
    /etc/systemd/system/v2ray.service.d \
    /etc/caddy \
    /etc/systemd/system/caddy.service \
    /etc/systemd/system/caddy.service.d \
    /etc/sysctl.d/99-bbr.conf \
    /etc/modules-load.d/bbr.conf
do
    if [[ -e "$FILE" ]]; then
        cp -a --parents "$FILE" "$BACKUP/"
    fi
done
echo "备份位置：$BACKUP"

info "检查并释放 Caddy 使用的端口"
systemctl stop caddy 2>/dev/null || true

for PORT in 80 443; do
    if ss -H -ltn "sport = :${PORT}" | grep -q .; then
        ss -ltnp "sport = :${PORT}" || true
        systemctl start caddy 2>/dev/null || true
        die "TCP ${PORT} 仍被其他进程占用。请先检查进程，再重新运行脚本。"
    fi
done

systemctl stop v2ray 2>/dev/null || true

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

info "下载并安装 V2Ray 官方最新正式版"
curl -fLsS --retry 3 "$V2RAY_INSTALLER" -o "$TMP/install-release.sh"
bash -n "$TMP/install-release.sh" ||
    die "V2Ray 官方安装脚本语法检查失败。"
bash "$TMP/install-release.sh" --force

info "更新 V2Ray GeoIP 和 GeoSite 数据"
curl -fLsS --retry 3 "$GEO_INSTALLER" -o "$TMP/install-dat-release.sh"
bash -n "$TMP/install-dat-release.sh" ||
    die "Geo 数据安装脚本语法检查失败。"
bash "$TMP/install-dat-release.sh"

info "配置 Caddy 官方 Stable APT 源"
curl -fLsS --retry 3 "$CADDY_KEY" -o "$TMP/caddy-stable.asc"
gpg --dearmor --yes \
    -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg \
    "$TMP/caddy-stable.asc"

curl -fLsS --retry 3 "$CADDY_REPO" \
    -o /etc/apt/sources.list.d/caddy-stable.list

chmod 0644 \
    /usr/share/keyrings/caddy-stable-archive-keyring.gpg \
    /etc/apt/sources.list.d/caddy-stable.list

apt-get update
apt-get install -y caddy

info "启用 BBR（如果内核支持）"
cat > /etc/sysctl.d/99-bbr.conf <<'BBR'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
BBR

echo tcp_bbr > /etc/modules-load.d/bbr.conf
sysctl --system || warn "部分 sysctl 参数未生效，请检查内核支持情况。"
sysctl net.ipv4.tcp_congestion_control 2>/dev/null || true

info "生成 V2Ray 配置"
mkdir -p /usr/local/etc/v2ray /var/log/v2ray

if [[ "$PROTOCOL" == "vless" ]]; then
    CLIENTS='[{"id":"'"$UUID"'","level":1}]'
    SETTINGS='{"clients":'"$CLIENTS"',"decryption":"none"}'
else
    CLIENTS='[{"id":"'"$UUID"'","level":1,"alterId":0}]'
    SETTINGS='{"clients":'"$CLIENTS"'}'
fi

# 使用 jq 生成 JSON，避免手工拼接配置导致格式错误。
jq -n \
    --arg uuid "$UUID" \
    --arg protocol "$PROTOCOL" \
    --argjson port "$V2RAY_PORT" \
    '{
      log: {
        access: "/var/log/v2ray/access.log",
        error: "/var/log/v2ray/error.log",
        loglevel: "warning"
      },
      inbounds: [{
        listen: "127.0.0.1",
        port: $port,
        protocol: $protocol,
        settings:
          (if $protocol == "vless" then
             {clients:[{id:$uuid,level:1}],decryption:"none"}
           else
             {clients:[{id:$uuid,level:1,alterId:0}]}
           end),
        streamSettings: {
          network: "ws",
          wsSettings: {path:"/"}
        },
        sniffing: {
          enabled: true,
          destOverride: ["http","tls"]
        }
      }],
      outbounds: [
        {protocol:"freedom",settings:{domainStrategy:"UseIP"},tag:"direct"},
        {protocol:"freedom",settings:{domainStrategy:"UseIPv4"},tag:"force-ipv4"},
        {protocol:"freedom",settings:{domainStrategy:"UseIPv6"},tag:"force-ipv6"},
        {
          protocol:"socks",
          settings:{servers:[{address:"127.0.0.1",port:40000}]},
          tag:"socks5-warp"
        },
        {protocol:"blackhole",settings:{},tag:"blocked"}
      ],
      dns: {
        servers:["8.8.8.8","1.1.1.1","localhost"]
      },
      routing: {
        domainStrategy:"IPOnDemand",
        rules:[
          {
            type:"field",
            ip:[
              "0.0.0.0/8","10.0.0.0/8","100.64.0.0/10",
              "127.0.0.0/8","169.254.0.0/16","172.16.0.0/12",
              "192.0.0.0/24","192.0.2.0/24","192.168.0.0/16",
              "198.18.0.0/15","198.51.100.0/24","203.0.113.0/24",
              "::1/128","fc00::/7","fe80::/10"
            ],
            outboundTag:"blocked"
          },
          {type:"field",protocol:["bittorrent"],outboundTag:"blocked"}
        ]
      }
    }' > "$TMP/config.json"

info "生成 Caddy 配置"
cat > "$TMP/Caddyfile" <<CADDY
${DOMAIN} {
    encode gzip

    handle_path /${WS_PATH} {
        reverse_proxy 127.0.0.1:${V2RAY_PORT}
    }

    handle {
        reverse_proxy ${CAMO} {
            header_up Host {upstream_hostport}
        }
    }
}
CADDY

info "验证新配置"
/usr/local/bin/v2ray test -c "$TMP/config.json" ||
    die "V2Ray 配置测试失败。备份位置：$BACKUP"

caddy validate --config "$TMP/Caddyfile" --adapter caddyfile ||
    die "Caddy 配置测试失败。备份位置：$BACKUP"

info "安装验证通过的配置"
install -o root -g root -m 0644 "$TMP/config.json" "$V2RAY_CONFIG"
install -o root -g root -m 0644 "$TMP/Caddyfile" "$CADDYFILE"

touch /var/log/v2ray/access.log /var/log/v2ray/error.log
chown nobody:nogroup /var/log/v2ray/access.log /var/log/v2ray/error.log

info "启动服务"
systemctl daemon-reload
systemctl enable v2ray caddy
systemctl restart v2ray
systemctl restart caddy
sleep 2

if ! systemctl is-active --quiet v2ray; then
    journalctl -u v2ray -n 60 --no-pager || true
    die "V2Ray 启动失败。备份位置：$BACKUP"
fi

if ! systemctl is-active --quiet caddy; then
    journalctl -u caddy -n 60 --no-pager || true
    die "Caddy 启动失败。请检查 DNS、TCP 80/443 和证书日志。备份位置：$BACKUP"
fi

info "版本信息"
v2ray version || true
caddy version || true

if [[ "$PROTOCOL" == "vless" ]]; then
    LINK="vless://${UUID}@${DOMAIN}:443?encryption=none&security=tls&type=ws&host=${DOMAIN}&path=%2F${WS_PATH}#VLESS_WSS_${DOMAIN}"
else
    VMESS_JSON="$(jq -nc \
        --arg domain "$DOMAIN" \
        --arg uuid "$UUID" \
        --arg path "/$WS_PATH" \
        '{
          v:"2",
          ps:("VMess_WSS_"+$domain),
          add:$domain,
          port:"443",
          id:$uuid,
          aid:"0",
          net:"ws",
          type:"none",
          host:$domain,
          path:$path,
          tls:"tls"
        }')"
    LINK="vmess://$(printf '%s' "$VMESS_JSON" | base64 -w 0)"
fi

LINK_FILE="/root/v2ray-wss-node-link.txt"
printf '%s\n' "$LINK" > "$LINK_FILE"
chmod 0600 "$LINK_FILE"

info "安装完成"
echo "协议：$PROTOCOL"
echo "域名：$DOMAIN"
echo "端口：443"
echo "UUID：$UUID"
echo "WebSocket path：/$WS_PATH"
echo "内部端口：$V2RAY_PORT"
echo "连接链接："
echo "$LINK"

if command -v qrencode >/dev/null 2>&1; then
    echo
    qrencode -t UTF8 "$LINK" || true
fi

echo
echo "旧配置备份：$BACKUP"
echo "连接链接文件：$LINK_FILE"
echo
echo "检查命令："
echo "  systemctl status v2ray caddy --no-pager"
echo "  journalctl -u v2ray -n 100 --no-pager"
echo "  journalctl -u caddy -n 100 --no-pager"
echo "  v2ray test -c $V2RAY_CONFIG"
echo "  caddy validate --config $CADDYFILE"
echo
echo "请确保云服务商防火墙放行 TCP 80 和 TCP 443。"
echo "WARP 和自定义分流需要单独配置；本脚本不会自动安装 WARP。"
