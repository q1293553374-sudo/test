
共享
#!/usr/bin/env bash
# ==============================================================================
# clash-node.sh — 极简 sing-box 服务端
#   · 只面向 Clash / mihomo 客户端（Clash Verge Rev 等）
#   · 只开两种协议：VLESS + Reality (xtls-rprx-vision) / Hysteria2
#   · 只产出一份完整 clash.yaml，通过一个极简 HTTP 服务提供订阅
#   · 不使用 Cloudflare Argo / nginx / 多客户端模板
# 仅支持 systemd 的 Linux（Debian / Ubuntu / CentOS / Fedora / Arch 等）
# ==============================================================================
set -uo pipefail
APP="clash-node"
VER="1.0.0"
# ---- 可通过环境变量或参数覆盖的配置 ----
WORK_DIR="${WORK_DIR:-/etc/sing-box}"
BIN="${BIN:-/usr/local/bin/sing-box}"
SVC="sing-box"
SUB_SVC="clash-sub"
REALITY_PORT="${REALITY_PORT:-8443}"
HY2_PORT="${HY2_PORT:-9443}"
SUB_PORT="${SUB_PORT:-9080}"
SNI="${SNI:-addons.mozilla.org}"
LISTEN="${LISTEN:-::}"
NODE_NAME="${NODE_NAME:-node}"
SERVER_IP="${SERVER_IP:-}"
SB_VERSION="${SB_VERSION:-}"
FORCE=0
NO_FIREWALL=0
PKG_NAME=""
FW_ACTION=""
# ---- 运行时状态（安装时写入 ${WORK_DIR}/clash-node.conf） ----
UUID=""
REALITY_PRIVATE=""
REALITY_PUBLIC=""
SHORT_ID=""
CERT_FP=""
SUB_TOKEN=""
SUB_AUTH=1
SUB_USER="clash"
SUB_PASS=""
SUB_AUTH_ARG=""
SHORTCUT="${SHORTCUT:-/usr/local/bin/clash-node}"
LOG_LEVEL="${LOG_LEVEL:-warn}"
LOG_LEVEL_ARG=""
CLI_PORT_R=""
CLI_PORT_H=""
CLI_PORT_S=""
SB_VER=""
if [ -t 1 ]; then
C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_B=$'\033[36m'; C_0=$'\033[0m'
else
C_R=; C_G=; C_Y=; C_B=; C_0=
fi
info() { printf '%s[*]%s %s\n' "$C_B" "$C_0" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_Y" "$C_0" "$*"; }
die()  { printf '%s[x]%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
# doctor 用的计数与输出
DOC_BAD=0
DOC_WARN=0
doc_ok()   { printf '  %s✓%s %s\n' "$C_G" "$C_0" "$*"; }
doc_warn() { printf '  %s!%s %s\n' "$C_Y" "$C_0" "$*"; DOC_WARN=$((DOC_WARN + 1)); }
doc_bad()  { printf '  %s✗%s %s\n' "$C_R" "$C_0" "$*"; DOC_BAD=$((DOC_BAD + 1)); }
# ==============================================================================
# 基础工具
# ==============================================================================
usage() {
cat <<EOF
$APP $VER — sing-box 服务端（Reality + Hysteria2，仅供 Clash 客户端）
用法:
bash clash-node.sh install [选项]   # 安装
bash clash-node.sh info             # 查看订阅地址与节点信息
bash clash-node.sh sub              # 重新生成订阅（换 IP / 改端口后）
bash clash-node.sh rotate [--force] # 轮换订阅 token（--force 连节点凭据一起换）
bash clash-node.sh sub-auth [on|off|u:p]  # 开启/关闭订阅 Basic Auth
bash clash-node.sh log-level [级别]  # 查看/修改日志级别（none = 关闭）
bash clash-node.sh port [--port N] [--hy2-port N] [--sub-port N]  # 改端口（不换密钥）
bash clash-node.sh doctor           # 体检：服务/配置/端口/网关/DNS/出网/防火墙
bash clash-node.sh firewall [--open|--close]  # 查看/放行/移除本机防火墙规则
bash clash-node.sh status           # 查看服务状态
bash clash-node.sh restart          # 重启服务
bash clash-node.sh uninstall        # 卸载
选项:
--port <n>        Reality 端口，默认 8443 (TCP)
--hy2-port <n>    Hysteria2 端口，默认 9443 (UDP)
--sub-port <n>    订阅 HTTP 端口，默认 9080
--sni <domain>    Reality / 证书的 SNI，默认 addons.mozilla.org
--listen <addr>   监听地址，默认 ::（IPv4-only 主机请用 0.0.0.0）
--name <name>     节点名前缀，默认 node
--server-ip <ip>  对外 IP（不填则自动探测）
--version <ver>   指定 sing-box 版本（不填则取最新稳定版）
--sub-auth <u:p>  订阅 Basic Auth 凭据（默认 clash:<随机>）
--no-sub-auth     关闭订阅 Basic Auth
--log-level <lv>  sing-box 日志级别：trace/debug/info/warn/error/none（默认 warn）
--force           已安装时强制重装（会重新生成密钥）
EOF
}
fetch() {  # fetch <url> [--out <file>]
if [ "${2:-}" = "--out" ] && [ -n "${3:-}" ]; then
if have curl; then
curl -fsSL --retry 3 --connect-timeout 10 -o "$3" "$1"
else
wget -q --tries=3 --timeout=15 -O "$3" "$1"
fi
else
if have curl; then
curl -fsSL --retry 3 --connect-timeout 10 "$1"
else
wget -qO- --tries=3 --timeout=15 "$1"
fi
fi
}
detect_arch() {
case "$(uname -m)" in
x86_64 | amd64)   ARCH="amd64" ;;
aarch64 | arm64)  ARCH="arm64" ;;
armv7l | armv7)   ARCH="armv7" ;;
*) die "不支持的架构: $(uname -m)" ;;
esac
if [ -f /etc/alpine-release ] || { have ldd && ldd --version 2>&1 | grep -qi musl; }; then
ARCH="${ARCH}-musl"
fi
}
detect_pkg() {
if have apt-get; then
PKG_UPDATE=(apt-get update -y); PKG_INSTALL=(apt-get install -y); PKG_NAME=apt
elif have dnf; then
PKG_UPDATE=(dnf -y makecache); PKG_INSTALL=(dnf -y install); PKG_NAME=dnf
elif have yum; then
PKG_UPDATE=(yum -y makecache); PKG_INSTALL=(yum -y install); PKG_NAME=yum
elif have pacman; then
PKG_UPDATE=(pacman -Sy --noconfirm); PKG_INSTALL=(pacman -S --noconfirm); PKG_NAME=pacman
elif have apk; then
PKG_UPDATE=(apk update); PKG_INSTALL=(apk add --no-cache); PKG_NAME=apk
elif have zypper; then
PKG_UPDATE=(zypper --non-interactive refresh); PKG_INSTALL=(zypper --non-interactive install); PKG_NAME=zypper
else
die "未识别的包管理器，请手动安装: curl openssl tar python3"
fi
}
deps_hint() {  # 根据包管理器给出手动安装命令
case "${PKG_NAME:-}" in
apt)    echo "apt-get install -y $*" ;;
dnf)    echo "dnf install -y $*" ;;
yum)    echo "yum install -y $*" ;;
pacman) echo "pacman -S --noconfirm $*" ;;
apk)    echo "apk add $*" ;;
zypper) echo "zypper install -y $*" ;;
*)      echo "请手动安装 $*" ;;
esac
}
install_deps() {
local miss=() log
# 有 wget 就不强求 curl（fetch 会自动降级）
have curl || have wget || miss+=(curl)
have openssl || miss+=(openssl)
have tar || miss+=(tar)
have python3 || miss+=(python3)
[ "${#miss[@]}" -eq 0 ] && return 0
info "安装依赖: ${miss[*]}"
log=$(mktemp)
"${PKG_UPDATE[@]}" >"$log" 2>&1 || true
if ! "${PKG_INSTALL[@]}" "${miss[@]}" >>"$log" 2>&1; then
warn "依赖安装失败，包管理器最后输出："
tail -n 15 "$log" | sed 's/^/    /' >&2
rm -f "$log"
die "请手动安装: ${miss[*]}（例如: $(deps_hint "${miss[*]}")）"
fi
rm -f "$log"
have curl || have wget || die "缺少 curl/wget，无法继续"
}
port_in_use() {  # port_in_use <port> <tcp|udp>  返回 0 表示被占用
local port="$1" proto="${2:-tcp}" out
if have ss; then
if [ "$proto" = "udp" ]; then out=$(ss -Hlun 2>/dev/null); else out=$(ss -Hltn 2>/dev/null); fi
printf '%s\n' "$out" | awk '{print $4}' | grep -Eq "[:.]${port}\$"
else
have python3 || return 1   # 无 ss 也无 python3 时不做判断，交给后续依赖安装
python3 - "$port" "$proto" <<'PY'
import socket, sys
port, proto = int(sys.argv[1]), sys.argv[2]
# TCP：先尝试连接本机端口，能连上说明有人在监听
if proto != "udp":
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.settimeout(0.3)
try:
if s.connect_ex(("127.0.0.1", port)) == 0:
sys.exit(0)
finally:
s.close()
# 再尝试绑定（UDP 只能走这条路）
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM if proto == "udp" else socket.SOCK_STREAM)
try:
s.bind(("0.0.0.0", port))
sys.exit(1)   # 能绑定 => 空闲
except OSError:
sys.exit(0)   # 绑定失败 => 被占用
finally:
s.close()
PY
fi
}
ensure_free() {  # ensure_free <port> <tcp|udp> <说明>
if port_in_use "$1" "$2"; then
die "$3 端口 $1/$2 已被占用，请用对应参数换一个端口"
fi
}
get_public_ip() {
local ip u
for u in https://api.ipify.org https://ipv4.icanhazip.com https://ifconfig.me/ip https://ip.sb; do
ip=$(fetch "$u" 2>/dev/null | tr -d '[:space:]')
if [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
printf '%s' "$ip"; return 0
fi
done
return 1
}
require_systemd() {
have systemctl || die "本脚本仅支持 systemd 系统"
[ -d /run/systemd/system ] || die "systemd 未运行，本脚本不支持该环境"
}
# ==============================================================================
# 安装步骤
# ==============================================================================
sb_latest() {
local v
v=$(fetch "https://api.github.com/repos/SagerNet/sing-box/releases/latest" 2>/dev/null \
| sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\{0,1\}\([^"]*\)".*/\1/p' | head -n1)
if [ -z "$v" ]; then
v=$(fetch "https://github.com/SagerNet/sing-box/releases.atom" 2>/dev/null \
| sed -n '/alternate/ s#.*/tag/v\([^"]\+\)".*#\1#p' | head -n1)
fi
[ -n "$v" ] || return 1
printf '%s' "$v"
}
install_singbox() {
local v url tmp binfile
v="${SB_VERSION:-$(sb_latest)}"
[ -n "$v" ] || die "获取 sing-box 版本失败（GitHub 不可达？）"
info "安装 sing-box v${v} (linux-${ARCH})"
url="https://github.com/SagerNet/sing-box/releases/download/v${v}/sing-box-${v}-linux-${ARCH}.tar.gz"
tmp=$(mktemp -d)
fetch "$url" --out "$tmp/sb.tgz" >/dev/null 2>&1 || { rm -rf "$tmp"; die "下载失败: $url"; }
tar -xzf "$tmp/sb.tgz" -C "$tmp" >/dev/null 2>&1 || { rm -rf "$tmp"; die "解压失败"; }
binfile=$(find "$tmp" -type f -name 'sing-box' | head -n1)
[ -n "$binfile" ] || { rm -rf "$tmp"; die "压缩包内未找到 sing-box"; }
install -m 0755 "$binfile" "$BIN"
rm -rf "$tmp"
SB_VER=$("$BIN" version | awk '/version/{print $NF}')
[ -n "$SB_VER" ] || die "sing-box 安装后无法运行"
ok "sing-box $SB_VER"
}
gen_uuid() {
local u
u=$("$BIN" generate uuid 2>/dev/null)
[ -n "$u" ] || u=$(cat /proc/sys/kernel/random/uuid 2>/dev/null)
[ -n "$u" ] || u=$(openssl rand -hex 16)
printf '%s' "$u"
}
gen_reality() {
local out
out=$("$BIN" generate reality-keypair 2>/dev/null) || die "生成 Reality 密钥失败"
REALITY_PRIVATE=$(awk '/PrivateKey/{print $NF}' <<< "$out")
REALITY_PUBLIC=$(awk '/PublicKey/{print $NF}' <<< "$out")
[ -n "$REALITY_PRIVATE" ] && [ -n "$REALITY_PUBLIC" ] || die "解析 Reality 密钥失败"
SHORT_ID=$(openssl rand -hex 8)
}
gen_cert() {
mkdir -p "$WORK_DIR/cert"
openssl ecparam -genkey -name prime256v1 -out "$WORK_DIR/cert/key.pem" 2>/dev/null \
|| die "生成私钥失败"
cat > "$WORK_DIR/cert/req.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = ${SNI}
[v3]
subjectAltName = DNS:${SNI}
EOF
openssl req -new -x509 -days 3650 \
-key "$WORK_DIR/cert/key.pem" \
-out "$WORK_DIR/cert/cert.pem" \
-config "$WORK_DIR/cert/req.cnf" -extensions v3 2>/dev/null \
|| die "生成证书失败"
rm -f "$WORK_DIR/cert/req.cnf"
CERT_FP=$(openssl x509 -in "$WORK_DIR/cert/cert.pem" -noout -fingerprint -sha256 \
| sed 's/^.*=//; s/://g' | tr 'A-F' 'a-f')
[ -n "$CERT_FP" ] || die "计算证书指纹失败"
}
write_config() {
local log_disabled=false log_level="${LOG_LEVEL:-warn}"
case "$log_level" in
none | off | disabled) log_disabled=true; log_level="error" ;;
esac
mkdir -p "$WORK_DIR"
cat > "$WORK_DIR/config.json" <<EOF
{
"log": {
"disabled": ${log_disabled},
"level": "${log_level}",
"timestamp": true
},
"inbounds": [
{
"type": "vless",
"tag": "vless-reality",
"listen": "${LISTEN}",
"listen_port": ${REALITY_PORT},
"users": [
{
"uuid": "${UUID}",
"flow": "xtls-rprx-vision"
}
],
"tls": {
"enabled": true,
"server_name": "${SNI}",
"reality": {
"enabled": true,
"handshake": {
"server": "${SNI}",
"server_port": 443
},
"private_key": "${REALITY_PRIVATE}",
"short_id": ["${SHORT_ID}"]
}
}
},
{
"type": "hysteria2",
"tag": "hysteria2",
"listen": "${LISTEN}",
"listen_port": ${HY2_PORT},
"users": [
{
"password": "${UUID}"
}
],
"tls": {
"enabled": true,
"certificate_path": "${WORK_DIR}/cert/cert.pem",
"key_path": "${WORK_DIR}/cert/key.pem"
}
}
],
"outbounds": [
{
"type": "direct",
"tag": "direct"
}
]
}
EOF
chmod 600 "$WORK_DIR/config.json"
}
write_yaml() {
mkdir -p "$WORK_DIR/sub"
cat > "$WORK_DIR/sub/sub.yaml" <<EOF
# generated by ${APP} ${VER} at $(date '+%Y-%m-%d %H:%M:%S')
# sing-box ${SB_VER}
port: 7890
socks-port: 7891
allow-lan: false
mode: rule
log-level: info
ipv6: true
proxies:
- name: "${NODE_NAME}-reality"
type: vless
server: "${SERVER_IP}"
port: ${REALITY_PORT}
uuid: "${UUID}"
network: tcp
udp: true
tls: true
flow: xtls-rprx-vision
servername: "${SNI}"
client-fingerprint: chrome
reality-opts:
public-key: "${REALITY_PUBLIC}"
short-id: "${SHORT_ID}"
- name: "${NODE_NAME}-hy2"
type: hysteria2
server: "${SERVER_IP}"
port: ${HY2_PORT}
password: "${UUID}"
sni: "${SNI}"
skip-cert-verify: false
fingerprint: "${CERT_FP}"
proxy-groups:
- name: PROXY
type: select
proxies: ["auto", "${NODE_NAME}-reality", "${NODE_NAME}-hy2"]
- name: auto
type: url-test
proxies: ["${NODE_NAME}-reality", "${NODE_NAME}-hy2"]
url: http://www.gstatic.com/generate_204
interval: 300
tolerance: 50
rules:
- GEOIP,CN,DIRECT
- MATCH,PROXY
EOF
chmod 600 "$WORK_DIR/sub/sub.yaml"
}
write_sub_py() {
mkdir -p "$WORK_DIR/sub"
cat > "$WORK_DIR/sub/server.py" <<'PY'
#!/usr/bin/env python3
"""极简订阅服务：可选 Basic Auth；仅响应 /<token>.yaml，其余一律 404。"""
import base64
import hmac
import http.server
import os
import socketserver
import sys
BASE = os.environ.get("SUB_BASE", "/etc/sing-box/sub")
TOKEN = open(os.path.join(BASE, "token")).read().strip()
YAML = os.path.join(BASE, "sub.yaml")
PORT = int(sys.argv[1])
AUTH_FILE = os.path.join(BASE, "auth")
CRED = None
if os.path.exists(AUTH_FILE):
with open(AUTH_FILE) as f:
CRED = f.read().strip()
class Handler(http.server.BaseHTTPRequestHandler):
server_version = "clash-node-sub"
def _send(self, code, body=b"", ctype="text/plain; charset=utf-8", extra=None):
self.send_response(code)
self.send_header("Content-Type", ctype)
self.send_header("Content-Length", str(len(body)))
for k, v in (extra or []):
self.send_header(k, v)
self.end_headers()
if body:
self.wfile.write(body)
def _authorized(self):
if CRED is None:
return True
header = self.headers.get("Authorization", "")
if not header.startswith("Basic "):
return False
try:
raw = base64.b64decode(header[6:], validate=True).decode("utf-8")
except Exception:
return False
return hmac.compare_digest(raw.encode(), CRED.encode())
def do_GET(self):
if not self._authorized():
self._send(401, b"auth required\n",
extra=[("WWW-Authenticate", 'Basic realm="clash-node"')])
return
path = self.path.split("?")[0].strip("/")
if path != TOKEN + ".yaml":
self._send(404, b"not found\n")
return
try:
with open(YAML, "rb") as f:
data = f.read()
except OSError:
self._send(500, b"config missing\n")
return
self._send(200, data, "text/yaml; charset=utf-8")
def log_message(self, *args):
pass
class Server(socketserver.ThreadingTCPServer):
allow_reuse_address = True
daemon_threads = True
with Server(("0.0.0.0", PORT), Handler) as httpd:
httpd.serve_forever()
PY
chmod 755 "$WORK_DIR/sub/server.py"
}
write_sub_server() {
mkdir -p "$WORK_DIR/sub"
SUB_TOKEN=$(openssl rand -hex 16)
printf '%s' "$SUB_TOKEN" > "$WORK_DIR/sub/token"
chmod 600 "$WORK_DIR/sub/token"
if [ "${SUB_AUTH:-1}" = "1" ]; then
[ -n "${SUB_PASS:-}" ] || SUB_PASS=$(openssl rand -hex 12)
printf '%s:%s' "$SUB_USER" "$SUB_PASS" > "$WORK_DIR/sub/auth"
chmod 600 "$WORK_DIR/sub/auth"
else
rm -f "$WORK_DIR/sub/auth"
SUB_PASS=""
fi
write_sub_py
}
write_state() {
cat > "$WORK_DIR/clash-node.conf" <<EOF
UUID=${UUID}
REALITY_PRIVATE=${REALITY_PRIVATE}
REALITY_PUBLIC=${REALITY_PUBLIC}
SHORT_ID=${SHORT_ID}
REALITY_PORT=${REALITY_PORT}
HY2_PORT=${HY2_PORT}
SUB_PORT=${SUB_PORT}
SNI=${SNI}
LISTEN=${LISTEN}
