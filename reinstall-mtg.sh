
cat > /root/reinstall-mtg.sh <<'SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

REPO="9seconds/mtg"
PORT=8443
BIN="/usr/local/bin/mtg"
CONFIG="/etc/mtg.toml"
SERVICE="/etc/systemd/system/mtg.service"

die() { echo "错误：$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "请使用 root 运行"
[[ -f /etc/debian_version ]] || die "不是 Debian 系统"
grep -q '^12\([. ]\|$\)' /etc/debian_version ||
  die "此脚本只支持 Debian 12"

apt-get update
apt-get install -y ca-certificates curl jq tar coreutils iproute2

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64) ARCH="amd64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  *) die "不支持的架构：$ARCH" ;;
esac

echo "==> 查询官方正式版本"
RELEASE="$(curl -fsSL --retry 3 \
  "https://api.github.com/repos/${REPO}/releases/latest")"
VERSION="$(jq -er '.tag_name' <<<"$RELEASE")"
[[ "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
  die "官方版本号异常"

V="${VERSION#v}"
ASSET="$(jq -er --arg a "$ARCH" '
  [.assets[].name
   | select(test("linux-" + $a + "\\.tar\\.gz$"))]
  | first // empty
' <<<"$RELEASE")" || die "找不到匹配架构的官方安装包"

SUMS="mtg-${V}-checksums.txt"
jq -e --arg s "$SUMS" \
  '.assets[].name | select(. == $s)' <<<"$RELEASE" >/dev/null ||
  die "官方校验文件不存在"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
BASE="https://github.com/${REPO}/releases/download/${VERSION}"

echo "==> 下载 ${VERSION}"
curl -fLsS --retry 3 "$BASE/$ASSET" -o "$TMP/$ASSET"
curl -fLsS --retry 3 "$BASE/$SUMS" -o "$TMP/checksums.txt"

HASH="$(awk -v f="$ASSET" '$NF == f {print $1; exit}' \
  "$TMP/checksums.txt")"
[[ "$HASH" =~ ^[a-fA-F0-9]{64}$ ]] ||
  die "未找到安装包的官方 SHA-256"

printf '%s  %s\n' "$HASH" "$TMP/$ASSET" |
  sha256sum -c - || die "校验失败，拒绝安装"

mkdir "$TMP/unpack"
tar -xzf "$TMP/$ASSET" -C "$TMP/unpack"
FOUND="$(find "$TMP/unpack" -type f -name mtg -perm /111 -print -quit)"
[[ -n "$FOUND" ]] || die "压缩包中没有 mtg 可执行文件"

echo
read -r -p "输入 FakeTLS 域名（建议与你的 VPS 网络或服务商有关联）: " DOMAIN
[[ "$DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]] || die "域名格式无效"
[[ "$DOMAIN" == *.* && "$DOMAIN" != .* && "$DOMAIN" != *. ]] ||
  die "请输入完整域名"

echo
echo "==> 备份旧配置、服务文件和程序"
BACKUP="/root/mtg-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -m 0700 -p "$BACKUP"

for f in "$CONFIG" "$SERVICE" "$BIN"; do
  if [[ -e "$f" ]]; then
    cp -a "$f" "$BACKUP/"
    echo "已备份：$f"
  fi
done
echo "备份位置：$BACKUP"

echo "==> 停止旧 mtg 服务"
systemctl stop mtg 2>/dev/null || true

echo "==> 检查 TCP ${PORT}"
if ss -H -ltn "sport = :${PORT}" | grep -q .; then
  ss -ltnp "sport = :${PORT}" || true
  die "8443 仍被占用，停止安装；请先确认占用进程"
fi

echo "==> 安装新程序"
install -o root -g root -m 0755 "$FOUND" "$BIN"
"$BIN" --version

echo "==> 创建专用服务用户"
if ! getent group mtg >/dev/null 2>&1; then
  groupadd --system mtg
fi
if ! id mtg >/dev/null 2>&1; then
  useradd --system --gid mtg --no-create-home \
    --shell /usr/sbin/nologin mtg
fi

echo "==> 生成新的代理密钥"
SECRET="$("$BIN" generate-secret --hex "$DOMAIN")"
[[ "$SECRET" == ee* ]] || die "密钥格式异常"

echo "==> 写入新配置"
install -o root -g mtg -m 0640 /dev/null "$CONFIG"
printf 'secret = "%s"\nbind-to = "0.0.0.0:%s"\n' \
  "$SECRET" "$PORT" > "$CONFIG"

echo "==> 写入 systemd 服务"
cat > "$SERVICE" <<'UNIT'
[Unit]
Description=mtg Telegram MTProto Proxy
Documentation=https://github.com/9seconds/mtg
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=mtg
Group=mtg
ExecStart=/usr/local/bin/mtg run /etc/mtg.toml
Restart=on-failure
RestartSec=3
LimitNOFILE=65536
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true

[Install]
WantedBy=multi-user.target
UNIT

chmod 0644 "$SERVICE"
systemctl daemon-reload
systemctl enable mtg
systemctl restart mtg
sleep 2

if ! systemctl is-active --quiet mtg; then
  journalctl -u mtg -n 60 --no-pager || true
  die "启动失败。旧文件保存在 $BACKUP"
fi

echo
echo "==> 运行配置检查"
"$BIN" doctor "$CONFIG" ||
  echo "注意：doctor 有检查未通过，请查看上方信息"

echo
echo "==> 新的 Telegram 代理连接信息"
"$BIN" access "$CONFIG"

echo
echo "========== 重装完成 =========="
echo "端口：TCP $PORT"
echo "状态：systemctl status mtg --no-pager"
echo "日志：journalctl -u mtg -f"
echo "配置：$CONFIG"
echo "旧文件备份：$BACKUP"
echo "请在云服务商安全组放行 TCP $PORT。"
echo "请妥善保管上方输出的代理链接和密钥。"
SCRIPT

chmod 700 /root/reinstall-mtg.sh
bash -n /root/reinstall-mtg.sh && echo "语法检查通过"
