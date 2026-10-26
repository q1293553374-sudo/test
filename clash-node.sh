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

NODE_NAME=${NODE_NAME}

SERVER_IP=${SERVER_IP}

CERT_FP=${CERT_FP}

SUB_TOKEN=${SUB_TOKEN}

SUB_AUTH=${SUB_AUTH}

SUB_USER=${SUB_USER}

SUB_PASS=${SUB_PASS}

LOG_LEVEL=${LOG_LEVEL}

SB_VER=${SB_VER}

EOF

chmod 600 "$WORK_DIR/clash-node.conf"

}

load_state() {

[ -s "$WORK_DIR/clash-node.conf" ] || die "未检测到安装记录，请先执行 install"

# shellcheck disable=SC1090

. "$WORK_DIR/clash-node.conf"

}

install_units() {

cat > "/etc/systemd/system/${SVC}.service" <<EOF

[Unit]

Description=sing-box proxy server

After=network-online.target

Wants=network-online.target

[Service]

Type=simple

ExecStart=${BIN} run -c ${WORK_DIR}/config.json

Restart=on-failure

RestartSec=3

LimitNOFILE=65535

NoNewPrivileges=yes

ProtectSystem=full

ProtectHome=yes

PrivateTmp=yes

[Install]

WantedBy=multi-user.target

EOF

cat > "/etc/systemd/system/${SUB_SVC}.service" <<EOF

[Unit]

Description=Clash subscription HTTP server

After=network-online.target

Wants=network-online.target

[Service]

Type=simple

ExecStart=$(command -v python3) ${WORK_DIR}/sub/server.py ${SUB_PORT}

Restart=on-failure

RestartSec=3

NoNewPrivileges=yes

[Install]

WantedBy=multi-user.target

EOF

systemctl daemon-reload

}

# ------------------------------------------------------------------------------

# 防火墙：ufw / firewalld / iptables 自动处理；nftables 只给命令不代改

# ------------------------------------------------------------------------------

fw_backend() {

if have ufw && ufw status 2>/dev/null | grep -q "Status: active"; then

echo ufw; return

fi

if have firewall-cmd && systemctl is-active --quiet firewalld 2>/dev/null; then

echo firewalld; return

fi

if have nft && nft list ruleset 2>/dev/null | grep -qE 'hook[[:space:]]+input'; then

echo nftables; return

fi

if have iptables && iptables -S INPUT 2>/dev/null | grep -q '^-P INPUT DROP'; then

echo iptables; return

fi

echo none

}

fw_ports() {  # 输出 "tcp 443" 形式

printf 'tcp %s\nudp %s\ntcp %s\n' "$REALITY_PORT" "$HY2_PORT" "$SUB_PORT"

}

# 0=已放行 1=未放行 2=无法判断

fw_is_open() {

local port="$1" proto="$2" backend="$3"

case "$backend" in

ufw)

ufw status 2>/dev/null | grep -Eq "^${port}/${proto}[[:space:]]+ALLOW"

;;

firewalld)

firewall-cmd --query-port="${port}/${proto}" >/dev/null 2>&1

;;

iptables)

iptables -C INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null && return 0

have ip6tables && ip6tables -C INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null && return 0

return 1

;;

nftables)

return 2

;;

*)

return 0   # 没有本机防火墙

;;

esac

}

_ipt_open() {

local proto="$1" port="$2" cmd

for cmd in iptables ip6tables; do

have "$cmd" || continue

"$cmd" -C INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null && continue

"$cmd" -I INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null || true

done

}

_ipt_close() {

local proto="$1" port="$2" cmd

for cmd in iptables ip6tables; do

have "$cmd" || continue

while "$cmd" -C INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null; do

"$cmd" -D INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null || break

done

done

}

_ipt_save() {

if have netfilter-persistent; then

netfilter-persistent save >/dev/null 2>&1 && { ok "iptables 规则已持久化"; return; }

fi

if [ -d /etc/iptables ] && have iptables-save; then

iptables-save > /etc/iptables/rules.v4 2>/dev/null || true

have ip6tables-save && ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true

ok "iptables 规则已写入 /etc/iptables/"

return

fi

warn "iptables 规则未持久化，重启后会丢失；建议安装 iptables-persistent"

}

install_shortcut() {

local src="$0"

if [ ! -f "$src" ] || [ ! -r "$src" ]; then

warn "通过管道 / stdin 运行，未创建 ${SHORTCUT} 命令；请把脚本落地后用 bash 执行"

return

fi

# 已经是同一个文件就不重复安装

local abs

abs=$(cd "$(dirname "$src")" 2>/dev/null && pwd)/$(basename "$src")

if [ "$abs" = "$SHORTCUT" ]; then

return

fi

install -m 0755 "$src" "$SHORTCUT" 2>/dev/null \

&& ok "已安装命令: $(basename "$SHORTCUT")（可直接执行 $(basename "$SHORTCUT") sub-auth on）" \

|| warn "创建 ${SHORTCUT} 失败，可手动: cp ${src} ${SHORTCUT} && chmod 755 ${SHORTCUT}"

}

open_firewall() {

if [ "${NO_FIREWALL:-0}" = "1" ]; then

info "已跳过防火墙处理（--no-firewall）"

return

fi

local backend proto port

backend=$(fw_backend)

case "$backend" in

ufw)

while read -r proto port; do ufw allow "${port}/${proto}" >/dev/null 2>&1 || true; done < <(fw_ports)

ok "ufw 已放行：TCP ${REALITY_PORT} / UDP ${HY2_PORT} / TCP ${SUB_PORT}"

;;

firewalld)

local zone

zone=$(firewall-cmd --get-default-zone 2>/dev/null || echo public)

while read -r proto port; do

firewall-cmd --permanent --zone="$zone" --add-port="${port}/${proto}" >/dev/null 2>&1 || true

done < <(fw_ports)

firewall-cmd --reload >/dev/null 2>&1 || true

ok "firewalld(${zone}) 已放行：TCP ${REALITY_PORT} / UDP ${HY2_PORT} / TCP ${SUB_PORT}"

;;

iptables)

while read -r proto port; do _ipt_open "$proto" "$port"; done < <(fw_ports)

ok "iptables 已插入 ACCEPT 规则：TCP ${REALITY_PORT} / UDP ${HY2_PORT} / TCP ${SUB_PORT}"

_ipt_save

;;

nftables)

warn "检测到 nftables 规则集。为避免破坏你已有规则，脚本不自动修改，请手动执行："

while read -r proto port; do

echo "    nft add rule inet filter input ${proto} dport ${port} accept"

done < <(fw_ports)

echo "  （表/链名按你的实际配置调整，可用 nft list ruleset 查看）"

;;

none)

info "未检测到启用的本机防火墙（ufw/firewalld/iptables/nftables）"

;;

esac

info "云厂商安全组不归本机管，请确认已放行：TCP ${REALITY_PORT} / UDP ${HY2_PORT} / TCP ${SUB_PORT}"

warn "订阅端口 ${SUB_PORT} 对外开放，建议在安全组里限制来源 IP"

}

close_firewall() {

[ "${NO_FIREWALL:-0}" = "1" ] && return

local backend proto port

backend=$(fw_backend)

case "$backend" in

ufw)

while read -r proto port; do ufw delete allow "${port}/${proto}" >/dev/null 2>&1 || true; done < <(fw_ports)

;;

firewalld)

local zone

zone=$(firewall-cmd --get-default-zone 2>/dev/null || echo public)

while read -r proto port; do

firewall-cmd --permanent --zone="$zone" --remove-port="${port}/${proto}" >/dev/null 2>&1 || true

done < <(fw_ports)

firewall-cmd --reload >/dev/null 2>&1 || true

;;

iptables)

while read -r proto port; do _ipt_close "$proto" "$port"; done < <(fw_ports)

_ipt_save

;;

esac

}

cmd_firewall() {

load_state

local backend proto port rc

backend=$(fw_backend)

case "${FW_ACTION:-show}" in

open)

open_firewall

;;

close)

close_firewall

ok "已移除本脚本添加的防火墙规则"

;;

esac

echo

info "当前本机防火墙后端：${backend}"

while read -r proto port; do

fw_is_open "$port" "$proto" "$backend"

rc=$?

if [ "$rc" -eq 0 ]; then

doc_ok "${port}/${proto} 已放行"

elif [ "$rc" -eq 1 ]; then

doc_bad "${port}/${proto} 未放行"

else

doc_warn "${port}/${proto} 无法判断（nftables，请用 nft list ruleset 确认）"

fi

done < <(fw_ports)

# 防止"开了防火墙把自己关在门外"

if [ "$backend" = "ufw" ] && ! ufw status 2>/dev/null | grep -qE '^22(/tcp)?[[:space:]]+ALLOW'; then

warn "未发现 SSH(22) 放行规则；远程服务器请先执行: ufw allow 22/tcp"

fi

if [ "$backend" = "iptables" ] && ! iptables -C INPUT -p tcp --dport 22 -j ACCEPT 2>/dev/null; then

warn "INPUT 策略为 DROP 但未见 22/tcp 的 ACCEPT；远程服务器请确认 SSH 不会被断"

fi

echo

echo "  用法: bash clash-node.sh firewall [--open|--close]"

}

sub_url() {  # sub_url [host]

local host="${1:-$SERVER_IP}"

if [ "${SUB_AUTH:-0}" = "1" ] && [ -n "${SUB_PASS:-}" ]; then

printf 'http://%s:%s@%s:%s/%s.yaml' "$SUB_USER" "$SUB_PASS" "$host" "$SUB_PORT" "$SUB_TOKEN"

else

printf 'http://%s:%s/%s.yaml' "$host" "$SUB_PORT" "$SUB_TOKEN"

fi

}

print_result() {

local url; url=$(sub_url)

echo

ok "安装完成"

echo "  服务端: sing-box ${SB_VER}  配置 ${WORK_DIR}/config.json"

echo "  Reality: ${SERVER_IP}:${REALITY_PORT} (TCP)  SNI=${SNI}"

echo "  Hysteria2: ${SERVER_IP}:${HY2_PORT} (UDP)"

echo

echo "  Clash 订阅地址:"

printf '    %s%s%s\n' "$C_G" "$url" "$C_0"

echo

if [ "${SUB_AUTH:-0}" = "1" ]; then

echo "  （已启用 Basic Auth：URL 里含用户名密码，缺一个都下载不了）"

fi

echo "  Clash Verge: 订阅 → 新建 → 粘贴上面的 URL → 导入"

echo "  备用: 直接取用 ${WORK_DIR}/sub/sub.yaml"

echo

}

# ==============================================================================

# 命令

# ==============================================================================

cmd_install() {

require_systemd

detect_arch

detect_pkg

if systemctl is-active --quiet "$SVC" 2>/dev/null && [ "$FORCE" != "1" ]; then

die "sing-box 已在运行；重装请加 --force（会重新生成密钥，旧节点立即失效）"

fi

local p

for p in "$REALITY_PORT" "$HY2_PORT" "$SUB_PORT"; do

[[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -ge 1 ] && [ "$p" -le 65535 ] || die "端口不合法: $p"

done

[ "$REALITY_PORT" != "$HY2_PORT" ] && [ "$HY2_PORT" != "$SUB_PORT" ] && [ "$REALITY_PORT" != "$SUB_PORT" ] \

|| die "三个端口不能相同"

[[ "$NODE_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || die "节点名只能包含字母、数字、点、下划线、短横线"

[[ "$SNI" =~ ^[A-Za-z0-9.-]+$ ]]        || die "SNI 不是合法域名"

case "${LOG_LEVEL:-warn}" in

trace | debug | info | warn | error | fatal | panic | none | off | disabled) ;;

*) die "不支持的日志级别: ${LOG_LEVEL}（trace/debug/info/warn/error/none）" ;;

esac

if [ "${SUB_AUTH:-1}" = "1" ]; then

[[ "$SUB_USER" =~ ^[A-Za-z0-9._-]+$ ]] || die "Basic Auth 用户名只能包含字母、数字、. _ -"

if [ -n "$SUB_PASS" ] && ! [[ "$SUB_PASS" =~ ^[A-Za-z0-9._~-]+$ ]]; then

die "Basic Auth 密码只能包含字母、数字、. _ ~ -（避免 URL 转义问题）"

fi

fi

install_deps

ensure_free "$REALITY_PORT" tcp "Reality"

ensure_free "$HY2_PORT"     udp "Hysteria2"

ensure_free "$SUB_PORT"     tcp "订阅"

install_singbox

gen_reality

gen_cert

UUID=$(gen_uuid)

if [ -z "$SERVER_IP" ]; then

SERVER_IP=$(get_public_ip) || die "自动获取公网 IP 失败，请用 --server-ip 指定"

fi

[[ "$SERVER_IP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ || "$SERVER_IP" =~ ^[0-9A-Fa-f:]+$ ]] \

|| die "服务器地址不合法: $SERVER_IP"

mkdir -p "$WORK_DIR"

write_config

if ! "$BIN" check -c "$WORK_DIR/config.json"; then

die "sing-box 配置校验失败（见上方报错）"

fi

write_sub_server

write_yaml

write_state

chmod 700 "$WORK_DIR"

chmod 600 "$WORK_DIR/config.json" "$WORK_DIR/clash-node.conf" \

"$WORK_DIR/cert/key.pem" "$WORK_DIR/sub/sub.yaml"

install_units

systemctl enable --now "$SVC"     >/dev/null 2>&1 || true

systemctl enable --now "$SUB_SVC" >/dev/null 2>&1 || true

sleep 1

systemctl is-active --quiet "$SVC" || die "sing-box 启动失败，请执行: journalctl -u $SVC -n 30 --no-pager"

systemctl is-active --quiet "$SUB_SVC" || warn "订阅服务未启动，执行: journalctl -u $SUB_SVC -n 30 --no-pager"

install_shortcut

open_firewall

print_result

}

cmd_sub_auth() {

require_systemd

load_state

local arg="${SUB_AUTH_ARG:-}"

case "$arg" in

"")

if [ "${SUB_AUTH:-0}" = "1" ] && [ -n "${SUB_PASS:-}" ]; then

echo "  Basic Auth : 已启用（用户 ${SUB_USER}）"

else

echo "  Basic Auth : 未启用"

fi

echo "  订阅地址   : $(sub_url)"

echo

echo "  用法: bash clash-node.sh sub-auth [on|off|用户名:密码]"

return

;;

on)

SUB_AUTH=1

[ -n "${SUB_PASS:-}" ] || SUB_PASS=$(openssl rand -hex 12)

;;

off)

SUB_AUTH=0

SUB_PASS=""

;;

*:*)

SUB_USER="${arg%%:*}"

SUB_PASS="${arg#*:}"

SUB_AUTH=1

;;

*)

die "用法: bash clash-node.sh sub-auth [on|off|用户名:密码]"

;;

esac

if [ "$SUB_AUTH" = "1" ]; then

[[ "$SUB_USER" =~ ^[A-Za-z0-9._-]+$ ]] || die "用户名只能包含字母、数字、. _ -"

[[ "$SUB_PASS" =~ ^[A-Za-z0-9._~-]+$ ]] || die "密码只能包含字母、数字、. _ ~ -"

printf '%s:%s' "$SUB_USER" "$SUB_PASS" > "$WORK_DIR/sub/auth"

chmod 600 "$WORK_DIR/sub/auth"

else

rm -f "$WORK_DIR/sub/auth"

fi

write_sub_py

write_state

systemctl restart "$SUB_SVC" >/dev/null 2>&1 || true

ok "Basic Auth 已更新"

echo "  订阅地址: $(sub_url)"

}

cmd_port() {

require_systemd

load_state

if [ -z "$CLI_PORT_R" ] && [ -z "$CLI_PORT_H" ] && [ -z "$CLI_PORT_S" ]; then

echo "  Reality  : ${REALITY_PORT}/tcp"

echo "  Hysteria2: ${HY2_PORT}/udp"

echo "  订阅     : ${SUB_PORT}/tcp"

echo

echo "  用法: clash-node port [--port N] [--hy2-port N] [--sub-port N]"

return

fi

local old_r="$REALITY_PORT" old_h="$HY2_PORT" old_s="$SUB_PORT"

[ -n "$CLI_PORT_R" ] && REALITY_PORT="$CLI_PORT_R"

[ -n "$CLI_PORT_H" ] && HY2_PORT="$CLI_PORT_H"

[ -n "$CLI_PORT_S" ] && SUB_PORT="$CLI_PORT_S"

local p

for p in "$REALITY_PORT" "$HY2_PORT" "$SUB_PORT"; do

[[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -ge 1 ] && [ "$p" -le 65535 ] || die "端口不合法: $p"

done

[ "$REALITY_PORT" != "$HY2_PORT" ] && [ "$HY2_PORT" != "$SUB_PORT" ] && [ "$REALITY_PORT" != "$SUB_PORT" ] \

|| die "三个端口不能相同"

# 先停 sing-box，否则「新端口正好是旧端口」会被自己占用而误判

systemctl stop "$SVC" >/dev/null 2>&1 || true

local bad=""

if [ "$REALITY_PORT" != "$old_r" ] && port_in_use "$REALITY_PORT" tcp; then

bad="Reality ${REALITY_PORT}/tcp"

elif [ "$HY2_PORT" != "$old_h" ] && port_in_use "$HY2_PORT" udp; then

bad="Hysteria2 ${HY2_PORT}/udp"

elif [ "$SUB_PORT" != "$old_s" ] && port_in_use "$SUB_PORT" tcp; then

bad="订阅 ${SUB_PORT}/tcp"

fi

if [ -n "$bad" ]; then

systemctl start "$SVC" >/dev/null 2>&1 || true

die "新端口被占用: ${bad}（已按旧配置恢复）"

fi

write_config

if ! "$BIN" check -c "$WORK_DIR/config.json" >/dev/null 2>&1; then

# 校验失败：按旧端口恢复配置并重新拉起

REALITY_PORT="$old_r"; HY2_PORT="$old_h"; SUB_PORT="$old_s"

write_config

systemctl start "$SVC" >/dev/null 2>&1 || true

die "配置校验失败，已恢复原端口"

fi

# 订阅服务的端口写在 systemd unit 的 ExecStart 里，需要重写 unit

install_units

systemctl restart "$SVC"     >/dev/null 2>&1 || true

systemctl restart "$SUB_SVC" >/dev/null 2>&1 || true

write_yaml

write_state

# 防火墙：按旧端口清规则，再按新端口放行

REALITY_PORT="$old_r" HY2_PORT="$old_h" SUB_PORT="$old_s" close_firewall

open_firewall

ok "端口已更新（UUID / 密钥未变）"

echo "  Reality  : ${REALITY_PORT}/tcp"

echo "  Hysteria2: ${HY2_PORT}/udp"

echo "  订阅     : ${SUB_PORT}/tcp"

echo

echo "  订阅地址: $(sub_url)"

if [ "$SUB_PORT" != "$old_s" ]; then

warn "订阅端口变了，客户端需要更新订阅地址"

else

echo "  订阅地址未变，客户端刷新订阅即可"

fi

}

cmd_log_level() {

require_systemd

load_state

local arg="${LOG_LEVEL_ARG:-}"

if [ -z "$arg" ]; then

echo "  当前日志级别: ${LOG_LEVEL:-warn}"

echo "  用法: bash clash-node.sh log-level [trace|debug|info|warn|error|none]"

return

fi

case "$arg" in

trace | debug | info | warn | error | fatal | panic | none | off | disabled) ;;

*) die "不支持的日志级别: $arg" ;;

esac

LOG_LEVEL="$arg"

write_config

if ! "$BIN" check -c "$WORK_DIR/config.json" >/dev/null 2>&1; then

die "配置校验失败，未做修改"

fi

systemctl restart "$SVC" >/dev/null 2>&1 || true

write_state

ok "日志级别已设为 ${arg}"

if [ "$arg" = "none" ] || [ "$arg" = "off" ] || [ "$arg" = "disabled" ]; then

warn "sing-box 日志已关闭；排障时记得改回来: clash-node log-level warn"

fi

}

cmd_rotate() {

require_systemd

load_state

local old_token="${SUB_TOKEN:-}"

# --force：连节点凭据一起换（UUID / Hysteria2 密码），旧配置立即失效

if [ "$FORCE" = "1" ]; then

UUID=$(gen_uuid)

write_config

if ! "$BIN" check -c "$WORK_DIR/config.json" >/dev/null 2>&1; then

die "新配置校验失败，未做任何修改"

fi

systemctl restart "$SVC" >/dev/null 2>&1 || true

write_yaml

ok "节点凭据已轮换（UUID / 密码已更换）"

fi

# --force 且启用了 Basic Auth 时，连订阅密码一起换

if [ "$FORCE" = "1" ] && [ "${SUB_AUTH:-0}" = "1" ]; then

SUB_PASS=$(openssl rand -hex 12)

printf '%s:%s' "$SUB_USER" "$SUB_PASS" > "$WORK_DIR/sub/auth"

chmod 600 "$WORK_DIR/sub/auth"

ok "订阅密码已轮换"

fi

SUB_TOKEN=$(openssl rand -hex 16)

printf '%s' "$SUB_TOKEN" > "$WORK_DIR/sub/token"

chmod 600 "$WORK_DIR/sub/token"

write_state

systemctl restart "$SUB_SVC" >/dev/null 2>&1 || true

ok "订阅 token 已轮换"

echo "  旧 token: ${old_token:-（无）}"

echo "  新地址  : $(sub_url)"

echo

warn "旧订阅地址立即失效，Clash 客户端需重新导入"

if [ "$FORCE" != "1" ]; then

warn "注意：token 只挡订阅下载；已经拿到节点参数的人仍可继续连接"

warn "要彻底断开旧连接，请执行: bash clash-node.sh rotate --force"

fi

}

cmd_info() {

load_state

local url

if [ -n "${SUB_TOKEN:-}" ]; then

url=$(sub_url)

else

url="(状态文件缺少订阅 token，请重新 install --force)"

fi

echo "  sing-box : ${SB_VER} ($(systemctl is-active "$SVC" 2>/dev/null))"

echo "  Reality  : ${SERVER_IP}:${REALITY_PORT}/tcp  SNI=${SNI}"

echo "  Hysteria2: ${SERVER_IP}:${HY2_PORT}/udp"

echo "  订阅     : ${url}"

if [ "${SUB_AUTH:-0}" = "1" ] && [ -n "${SUB_PASS:-}" ]; then

echo "  认证     : Basic ${SUB_USER}:${SUB_PASS}"

else

echo "  认证     : 未启用"

fi

echo "  日志级别 : ${LOG_LEVEL:-warn}"

echo "  本地文件 : ${WORK_DIR}/sub/sub.yaml"

}

cmd_sub() {

require_systemd

# 允许命令行覆盖 IP：先暂存，读完状态文件后再写回

local override_ip="${SERVER_IP:-}"

load_state

[ -n "$override_ip" ] && SERVER_IP="$override_ip"

write_yaml

write_state

systemctl restart "$SUB_SVC" >/dev/null 2>&1 || true

ok "订阅已重新生成"

cmd_info

}

cmd_status() {

systemctl status "$SVC" --no-pager -l 2>/dev/null || true

echo

systemctl status "$SUB_SVC" --no-pager -l 2>/dev/null || true

}

# ------------------------------------------------------------------------------

# 体检：服务层 → 配置层 → 端口层 → 出网/网关层 → 订阅层 → 系统层

# ------------------------------------------------------------------------------

cmd_doctor() {

load_state

DOC_BAD=0

DOC_WARN=0

local url=""

[ -n "${SUB_TOKEN:-}" ] && url=$(sub_url 127.0.0.1)

local -a cargs=()

[ "${SUB_AUTH:-0}" = "1" ] && [ -n "${SUB_PASS:-}" ] && cargs=(-u "${SUB_USER}:${SUB_PASS}")

echo "== 1. 服务层 =="

if have systemctl; then

local s

for s in "$SVC" "$SUB_SVC"; do

if systemctl is-active --quiet "$s" 2>/dev/null; then

doc_ok "$s 运行中"

else

doc_bad "$s 未运行 → journalctl -u $s -n 50 --no-pager"

fi

done

else

doc_warn "没有 systemctl，无法检查服务状态"

fi

echo "== 2. 配置层 =="

if [ -x "$BIN" ] && "$BIN" check -c "$WORK_DIR/config.json" >/dev/null 2>&1; then

doc_ok "sing-box 配置校验通过"

else

doc_bad "sing-box 配置校验失败 → $BIN check -c $WORK_DIR/config.json"

fi

if [ -s "$WORK_DIR/cert/cert.pem" ] && openssl x509 -checkend 0 -noout -in "$WORK_DIR/cert/cert.pem" >/dev/null 2>&1; then

doc_ok "证书未过期"

else

doc_bad "证书缺失或已过期 → 重新 install --force"

fi

echo "== 3. 端口层 =="

if have ss; then

local proto port label out

for spec in "${REALITY_PORT}:tcp:Reality" "${HY2_PORT}:udp:Hysteria2" "${SUB_PORT}:tcp:订阅"; do

port="${spec%%:*}"; spec="${spec#*:}"; proto="${spec%%:*}"; label="${spec#*:}"

if [ "$proto" = "udp" ]; then out=$(ss -Hlun 2>/dev/null); else out=$(ss -Hltn 2>/dev/null); fi

if printf '%s\n' "$out" | awk '{print $4}' | grep -Eq "[:.]${port}\$"; then

doc_ok "$label 端口 ${port}/${proto} 已监听"

else

doc_bad "$label 端口 ${port}/${proto} 未监听"

fi

done

else

doc_warn "缺少 ss（iproute2），跳过端口检查"

fi

echo "== 4. 出网 / 网关层 =="

local gw

if have ip; then

gw=$(ip route show default 2>/dev/null | awk '/default/{print $3; exit}')

if [ -n "$gw" ]; then doc_ok "IPv4 默认网关 ${gw}"; else doc_bad "没有 IPv4 默认路由（服务器无法出网）"; fi

if ip -6 route show default 2>/dev/null | grep -q default; then

doc_ok "IPv6 默认路由存在"

else

doc_warn "无 IPv6 默认路由（客户端走 v6 会失败，可在订阅中关闭 ipv6）"

fi

else

doc_warn "缺少 ip 命令，跳过路由检查"

fi

if python3 -c 'import socket,sys; socket.gethostbyname(sys.argv[1])' "$SNI" >/dev/null 2>&1; then

doc_ok "DNS 可解析 ${SNI}"

else

doc_bad "DNS 无法解析 ${SNI}（Reality 握手会失败，检查 /etc/resolv.conf）"

fi

if python3 -c 'import socket,sys; s=socket.create_connection((sys.argv[1],443),3); s.close()' "$SNI" >/dev/null 2>&1; then

doc_ok "可连通 ${SNI}:443（Reality 握手目标）"

else

doc_bad "无法连通 ${SNI}:443（Reality 握手目标不可达）"

fi

local pub

pub=$(fetch https://api.ipify.org 2>/dev/null | tr -d '[:space:]')

if [ -n "$pub" ]; then

doc_ok "服务器可出网（HTTPS 出口 ${pub}）"

else

doc_bad "服务器无法通过 HTTPS 出网（检查网关/防火墙/DNS）"

fi

echo "== 5. 订阅层 =="

if [ -z "$url" ]; then

doc_bad "状态文件里没有订阅 token → 重新 install --force"

elif have curl && curl -fsS --max-time 3 ${cargs[@]+"${cargs[@]}"} "$url" >/dev/null 2>&1; then

doc_ok "订阅服务自检通过"

else

doc_bad "订阅服务自检失败 → curl -v $url"

fi

if [ -n "${SERVER_IP:-}" ]; then

doc_ok "对外地址 ${SERVER_IP}（确认云安全组已放行 TCP ${REALITY_PORT}/UDP ${HY2_PORT}/TCP ${SUB_PORT}）"

fi

echo "== 6. 系统层 =="

if have timedatectl; then

if timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -q yes; then

doc_ok "时间已同步"

else

doc_warn "时间未同步（Reality/TLS 对时钟偏差敏感）→ timedatectl set-ntp true"

fi

fi

if have df; then

local use

use=$(df -P "$WORK_DIR" 2>/dev/null | awk 'NR==2{gsub(/%/,"",$5); print $5}')

if [ -n "$use" ] && [ "$use" -lt 90 ]; then

doc_ok "磁盘使用 ${use}%"

else

doc_warn "磁盘使用 ${use:-?}%（偏高）"

fi

fi

echo "== 7. 防火墙 =="

local fwb fproto fport frc

fwb=$(fw_backend)

if [ "$fwb" = "none" ]; then

doc_ok "未启用本机防火墙"

else

doc_ok "后端: ${fwb}"

while read -r fproto fport; do

fw_is_open "$fport" "$fproto" "$fwb"

frc=$?

if [ "$frc" -eq 0 ]; then

doc_ok "${fport}/${fproto} 已放行"

elif [ "$frc" -eq 1 ]; then

doc_bad "${fport}/${fproto} 未放行 → bash clash-node.sh firewall --open"

else

doc_warn "${fport}/${fproto} 无法判断（nftables，用 nft list ruleset 确认）"

fi

done < <(fw_ports)

fi

echo

if [ "$DOC_BAD" -eq 0 ]; then

ok "体检通过（${DOC_WARN} 个提示）"

else

die "发现 ${DOC_BAD} 个问题（${DOC_WARN} 个提示）"

fi

}

cmd_restart() {

require_systemd

systemctl restart "$SVC"     || die "重启 sing-box 失败"

systemctl restart "$SUB_SVC" >/dev/null 2>&1 || true

ok "已重启"

systemctl is-active "$SVC"

}

cmd_uninstall() {

require_systemd

[ -d "$WORK_DIR" ] || die "未安装"

if [ -t 0 ] && [ "$FORCE" != "1" ]; then

local a

read -r -p "确认卸载 sing-box 并删除 ${WORK_DIR}? [y/N] " a

[ "$(printf '%s' "$a" | tr 'A-Z' 'a-z')" = "y" ] || { echo "已取消"; exit 0; }

fi

systemctl disable --now "$SUB_SVC" >/dev/null 2>&1 || true

systemctl disable --now "$SVC"     >/dev/null 2>&1 || true

rm -f "/etc/systemd/system/${SVC}.service" "/etc/systemd/system/${SUB_SVC}.service"

systemctl daemon-reload >/dev/null 2>&1 || true

# 尽量在删除状态文件前清理防火墙

if [ -s "$WORK_DIR/clash-node.conf" ]; then

# shellcheck disable=SC1090

. "$WORK_DIR/clash-node.conf"

close_firewall

fi

rm -rf "$WORK_DIR"

[ -f "$BIN" ] && rm -f "$BIN"

[ -f "$SHORTCUT" ] && rm -f "$SHORTCUT"

ok "已卸载"

}

main() {

local cmd="${1:-}"

[ $# -gt 0 ] && shift

# 这几个命令支持位置参数

case "$cmd" in

sub-auth | log-level)

if [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; then

if [ "$cmd" = "sub-auth" ]; then SUB_AUTH_ARG="$1"; else LOG_LEVEL_ARG="$1"; fi

shift

fi

;;

esac

while [ $# -gt 0 ]; do

case "$1" in

--port | --hy2-port | --sub-port | --sni | --listen | --name | --server-ip | --version | --sub-auth | --log-level)

[ $# -ge 2 ] || die "参数 $1 缺少取值"

case "$1" in

--port)      REALITY_PORT="$2"; CLI_PORT_R="$2" ;;

--hy2-port)  HY2_PORT="$2"; CLI_PORT_H="$2" ;;

--sub-port)  SUB_PORT="$2"; CLI_PORT_S="$2" ;;

--sni)       SNI="$2" ;;

--listen)    LISTEN="$2" ;;

--name)      NODE_NAME="$2" ;;

--server-ip) SERVER_IP="$2" ;;

--version)   SB_VERSION="$2" ;;

--sub-auth)

[[ "$2" == *:* ]] || die "--sub-auth 格式应为 用户名:密码"

SUB_USER="${2%%:*}"; SUB_PASS="${2#*:}"; SUB_AUTH=1 ;;

--log-level) LOG_LEVEL="$2" ;;

esac

shift 2

;;

--force)       FORCE=1; shift ;;

--no-firewall) NO_FIREWALL=1; shift ;;

--no-sub-auth) SUB_AUTH=0; shift ;;

--open)        FW_ACTION=open; shift ;;

--close)       FW_ACTION=close; shift ;;

-h | --help)  usage; exit 0 ;;

*)            die "未知参数: $1" ;;

esac

done

case "$cmd" in

install)   cmd_install ;;

info)      cmd_info ;;

sub)       cmd_sub ;;

rotate)    cmd_rotate ;;

log-level) cmd_log_level ;;

port)      cmd_port ;;

sub-auth)  cmd_sub_auth ;;

status)    cmd_status ;;

doctor)    cmd_doctor ;;

firewall)  cmd_firewall ;;

restart)   cmd_restart ;;

uninstall) cmd_uninstall ;;

"" | -h | --help) usage ;;

*)         die "未知命令: $cmd" ;;

esac

}

# 直接执行、进程替换、或通过 stdin 管道（curl | bash / ssh 'bash -s'）时都进入 main

if [ "${BASH_SOURCE[0]:-}" = "$0" ] || [ -z "${BASH_SOURCE[0]:-}" ]; then

main "$@"

fi