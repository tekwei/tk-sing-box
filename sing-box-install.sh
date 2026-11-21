#!/usr/bin/env bash
# Secure, repeatable sing-box installer for Debian/Ubuntu with systemd.
# Downloads only official SagerNet release assets and verifies GitHub's SHA-256 digest.
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

readonly API_BASE='https://api.github.com/repos/SagerNet/sing-box/releases'
readonly BIN='/usr/local/bin/sing-box'
readonly CONFIG_DIR='/etc/sing-box'
readonly CONFIG="$CONFIG_DIR/config.json"
readonly CLIENT_INFO="$CONFIG_DIR/client.txt"
readonly SERVICE='/etc/systemd/system/sing-box.service'
readonly USER_NAME='sing-box'
readonly GROUP_NAME='sing-box'

PORT='8443'
SNI='www.cloudflare.com'
VERSION='latest'
ACTION='install'
ARCH=''
PREVIOUS_BIN_BACKUP=''
SERVICE_NEEDS_BIND_CAP='no'

rollback_on_failure() {
  local status=$?
  if ((status != 0)) && [[ -n "$PREVIOUS_BIN_BACKUP" && -f "$PREVIOUS_BIN_BACKUP" ]]; then
    install -o root -g root -m 0755 -- "$PREVIOUS_BIN_BACKUP" "$BIN" 2>/dev/null || true
    rm -f -- "$PREVIOUS_BIN_BACKUP"
    systemctl restart sing-box.service 2>/dev/null || true
  fi
}
trap rollback_on_failure EXIT

log() { printf '[sing-box] %s\n' "$*"; }
die() { printf '[sing-box] ERROR: %s\n' "$*" >&2; exit 1; }
usage() {
  cat <<'USAGE'
安全版 sing-box 安装脚本（Debian/Ubuntu + systemd）

用法：sudo bash sing-box-install.sh [选项]

选项：
  --port PORT       监听端口，默认 8443
  --sni HOST        Reality 握手域名，默认 www.cloudflare.com
  --version VERSION 安装指定稳定版，例如 1.14.4；默认 latest
  --update          更新 sing-box 程序并保留现有配置
  --status          显示服务状态
  --uninstall       停止并移除本脚本安装的程序和配置（会二次确认）
  -h, --help        显示帮助

首次安装会生成 VLESS + Reality 配置。配置和客户端密钥位于 /etc/sing-box/，
客户端信息文件权限为 600。脚本不会自动更改防火墙、SSH 或系统内核参数。
USAGE
}

while (($#)); do
  case "$1" in
    --port) (($# >= 2)) || die '--port 需要一个数值'; PORT="$2"; shift 2 ;;
    --sni) (($# >= 2)) || die '--sni 需要主机名'; SNI="$2"; shift 2 ;;
    --version) (($# >= 2)) || die '--version 需要版本号'; VERSION="$2"; shift 2 ;;
    --update) ACTION='update'; shift ;;
    --status) ACTION='status'; shift ;;
    --uninstall) ACTION='uninstall'; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知参数：$1（使用 --help 查看用法）" ;;
  esac
done

valid_port() {
  [[ "$PORT" =~ ^[0-9]{1,5}$ ]] && ((10#$PORT >= 1 && 10#$PORT <= 65535))
}
valid_sni() {
  [[ "$SNI" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$ ]] && [[ "$SNI" != *..* ]]
}

require_root() { [[ "$(id -u)" -eq 0 ]] || die '请以 root 身份运行。'; }

status_action() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl --no-pager --full status sing-box.service || true
  else
    die '未找到 systemctl。'
  fi
}

uninstall_action() {
  require_root
  printf '这将停止 sing-box 并删除 %s、%s、%s。输入 REMOVE 确认：' "$BIN" "$CONFIG_DIR" "$SERVICE" >&2
  local answer
  IFS= read -r answer || true
  [[ "$answer" == 'REMOVE' ]] || die '已取消卸载。'
  systemctl disable --now sing-box.service 2>/dev/null || true
  rm -f -- "$SERVICE" "$BIN" /usr/local/bin/sb /usr/local/libexec/sing-box-manager.py
  systemctl daemon-reload
  rm -rf -- "$CONFIG_DIR"
  log '卸载完成；保留系统用户和组，避免删除可能被其他服务复用的账户。'
}

[[ "$ACTION" != 'status' ]] || { status_action; exit 0; }
[[ "$ACTION" != 'uninstall' ]] || { uninstall_action; exit 0; }
require_root
valid_port || die '端口必须是 1 到 65535 的整数。'
valid_sni || die 'SNI 只允许使用 ASCII 域名或 IP 字符，不能包含连续点。'
[[ "$VERSION" == 'latest' || "$VERSION" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || die '版本号格式无效。'

[[ -r /etc/os-release ]] || die '无法识别操作系统。'
# shellcheck disable=SC1091
. /etc/os-release
[[ "${ID:-}" == 'debian' || "${ID:-}" == 'ubuntu' ]] || die '仅支持 Debian 和 Ubuntu。'
command -v systemctl >/dev/null 2>&1 || die '此系统未使用 systemd。'
case "$(uname -m)" in
  x86_64|amd64) ARCH='amd64' ;;
  aarch64|arm64) ARCH='arm64' ;;
  *) die "不支持的 CPU 架构：$(uname -m)；仅支持 amd64 和 arm64。" ;;
esac

ensure_dependencies() {
  local missing=()
  for c in curl python3 tar sha256sum install getent; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  if ((${#missing[@]})); then
    log '安装必要工具（不会升级现有软件包）。'
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends ca-certificates curl python3 tar
  fi
  for c in curl python3 tar sha256sum install getent; do
    command -v "$c" >/dev/null 2>&1 || die "缺少必要命令：$c"
  done
  python3 -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 8) else 1)' \
    || die '需要 Python 3.8 或更高版本。'
}

ensure_identity() {
  if ! getent group "$GROUP_NAME" >/dev/null 2>&1; then groupadd --system "$GROUP_NAME"; fi
  local group_entry group_gid group_members
  group_entry="$(getent group "$GROUP_NAME")"
  IFS=: read -r _ _ group_gid group_members <<< "$group_entry"
  [[ -z "$group_members" ]] || die 'sing-box 组已有其他成员；为保护配置凭据，停止安装。'
  if getent passwd | awk -F: -v gid="$group_gid" -v svc="$USER_NAME" '$4 == gid && $1 != svc { found=1 } END { exit !found }'; then
    die 'sing-box 组已被其他账户用作主组；为保护配置凭据，停止安装。'
  fi
  if ! id "$USER_NAME" >/dev/null 2>&1; then
    useradd --system --gid "$GROUP_NAME" --home-dir /nonexistent \
      --shell /usr/sbin/nologin --no-create-home "$USER_NAME"
  else
    local passwd_entry account_name account_pass account_uid account_gid account_gecos account_home account_shell
    passwd_entry="$(getent passwd "$USER_NAME")"
    IFS=: read -r account_name account_pass account_uid account_gid account_gecos account_home account_shell <<< "$passwd_entry"
    [[ "$account_home" == '/nonexistent' && "$account_shell" == '/usr/sbin/nologin' && "$(id -gn "$USER_NAME")" == "$GROUP_NAME" ]] \
      || die 'sing-box 用户名已被其他账户占用；为避免复用高权限账户，停止安装。'
  fi
}

fetch_release() {
  local json api version asset_name record url digest archive tmpdir extracted
  json="$(mktemp)"
  archive="$(mktemp)"
  tmpdir="$(mktemp -d)"
  trap 'rm -f -- "${json:-}" "${archive:-}"; rm -rf -- "${tmpdir:-}"; trap - RETURN' RETURN

  if [[ "$VERSION" == 'latest' ]]; then
    api="$API_BASE/latest"
  else
    version="${VERSION#v}"
    api="$API_BASE/tags/v$version"
  fi
  curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
    --retry 3 --retry-all-errors --connect-timeout 15 --max-time 180 \
    -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28' \
    "$api" -o "$json"

  record="$(python3 - "$json" "$ARCH" <<'PY'
import json, re, sys
with open(sys.argv[1], encoding='utf-8') as f:
    release = json.load(f)
if release.get('draft') or release.get('prerelease'):
    raise SystemExit('拒绝安装草稿版或预发布版')
tag = release.get('tag_name', '')
version = tag[1:] if tag.startswith('v') else tag
if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+(?:[.-][0-9A-Za-z.-]+)?', version):
    raise SystemExit('Release 版本标签格式异常')
assets = release.get('assets', [])
arch = sys.argv[2]
name = f'sing-box-{version}-linux-{arch}.tar.gz'
asset = next((a for a in assets if a.get('name') == name), None)
if not asset:
    raise SystemExit(f'Release 中找不到所需文件：{name}')
digest = asset.get('digest', '')
if not re.fullmatch(r'sha256:[0-9a-fA-F]{64}', digest):
    raise SystemExit('GitHub Release 未提供 SHA-256 digest；为安全起见停止安装')
url = asset.get('browser_download_url', '')
if not url.startswith('https://github.com/SagerNet/sing-box/releases/download/'):
    raise SystemExit('下载地址不属于 sing-box 官方 Release')
print(version, name, digest.split(':', 1)[1].lower(), url, sep='\t')
PY
)" || die '读取或验证 GitHub Release 信息失败。'
  IFS=$'\t' read -r version asset_name digest url <<< "$record"
  [[ -n "$digest" && -n "$url" ]] || die 'Release 元数据不完整。'

  log "下载官方 sing-box v$version。"
  curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
    --retry 3 --retry-all-errors --connect-timeout 15 --max-time 600 \
    "$url" -o "$archive"
  printf '%s  %s\n' "$digest" "$archive" | sha256sum --check --status \
    || die '下载文件 SHA-256 校验失败。'

  tar -tzf "$archive" >/dev/null || die 'Release 压缩包无法读取。'
  tar --no-same-owner --no-same-permissions -xzf "$archive" -C "$tmpdir"
  extracted="$tmpdir/sing-box-$version-linux-$ARCH/sing-box"
  [[ -f "$extracted" && -x "$extracted" ]] || die 'Release 压缩包内没有预期的 sing-box 程序。'
  "$extracted" version >/dev/null 2>&1 || die '下载的 sing-box 程序无法启动。'

  local install_tmp
  install_tmp="$(mktemp /usr/local/bin/.sing-box.XXXXXX)"
  if [[ -x "$BIN" ]]; then
    PREVIOUS_BIN_BACKUP="$(mktemp /usr/local/bin/.sing-box.backup.XXXXXX)"
    cp -a -- "$BIN" "$PREVIOUS_BIN_BACKUP"
  fi
  install -o root -g root -m 0755 -- "$extracted" "$install_tmp"
  mv -f -- "$install_tmp" "$BIN"
  log "已安装 sing-box v$version。"
}

write_initial_config() {
  if [[ -e "$CONFIG" ]]; then
    [[ ! -L "$CONFIG" && -f "$CONFIG" ]] || die '配置路径必须是普通文件，不能是符号链接。'
    chown root:"$GROUP_NAME" "$CONFIG"
    chmod 0640 "$CONFIG"
    "$BIN" check -c "$CONFIG" || die '现有配置无法通过当前 sing-box 版本的检查；已停止启动服务。'
    if python3 - "$CONFIG" <<'PY'
import json, sys
with open(sys.argv[1], encoding='utf-8') as f:
    config = json.load(f)
raise SystemExit(0 if any(int(i.get('listen_port', 0)) < 1024 for i in config.get('inbounds', [])) else 1)
PY
    then SERVICE_NEEDS_BIND_CAP='yes'; fi
    log '保留现有配置并修正为 root:sing-box、0640 权限。'
    return
  fi
  local uuid reality private_key public_key short_id temp_config temp_client
  uuid="$(python3 -c 'import uuid; print(uuid.uuid4())')"
  reality="$("$BIN" generate reality-keypair)" || die 'Reality 密钥生成失败。'
  private_key="$(awk -F': *' '$1 ~ /PrivateKey/ {print $2; exit}' <<< "$reality")"
  public_key="$(awk -F': *' '$1 ~ /PublicKey/ {print $2; exit}' <<< "$reality")"
  [[ -n "$private_key" && -n "$public_key" ]] || die '无法解析 Reality 密钥生成结果。'
  short_id="$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
  temp_config="$(mktemp "$CONFIG_DIR/.config.XXXXXX")"
  temp_client="$(mktemp "$CONFIG_DIR/.client.XXXXXX")"

  python3 - "$PORT" "$SNI" "$uuid" "$private_key" "$short_id" > "$temp_config" <<'PY'
import json, sys
port, sni, user_id, private_key, short_id = sys.argv[1:]
config = {
  'log': {'level': 'warn', 'timestamp': True},
  'inbounds': [{
    'type': 'vless', 'tag': 'vless-reality-in', 'listen': '::',
    'listen_port': int(port), 'users': [{'uuid': user_id, 'flow': 'xtls-rprx-vision'}],
    'tls': {'enabled': True, 'server_name': sni,
      'reality': {'enabled': True,
        'handshake': {'server': sni, 'server_port': 443},
        'private_key': private_key, 'short_id': [short_id]}}
  }],
  'outbounds': [{'type': 'direct', 'tag': 'direct'}, {'type': 'block', 'tag': 'block'}],
  'route': {'final': 'direct'}
}
json.dump(config, sys.stdout, indent=2)
print()
PY
  chown root:"$GROUP_NAME" "$temp_config"
  chmod 0640 "$temp_config"
  "$BIN" check -c "$temp_config" || die 'sing-box 配置检查失败。'
  mv -f -- "$temp_config" "$CONFIG"
  if ((10#$PORT < 1024)); then SERVICE_NEEDS_BIND_CAP='yes'; fi

  cat > "$temp_client" <<EOF
sing-box VLESS Reality 客户端参数

服务器地址：请替换为本机公网 IP 或已解析到本机的域名
端口：$PORT
UUID：$uuid
传输：TCP
安全：Reality
SNI：$SNI
Reality 公钥：$public_key
Short ID：$short_id
Flow：xtls-rprx-vision
指纹：chrome

重要：此文件包含客户端连接凭据，请勿公开或发送给不可信对象。
EOF
  chown root:root "$temp_client"
  chmod 0600 "$temp_client"
  mv -f -- "$temp_client" "$CLIENT_INFO"
  install -d -o root -g "$GROUP_NAME" -m 0700 "$CONFIG_DIR/clients"
  python3 - "$CONFIG_DIR/clients/vless-reality-in.json" "$uuid" "$public_key" "$short_id" "$SNI" <<'PY'
import json, os, sys
path, user_uuid, public_key, short_id, sni = sys.argv[1:]
with open(path, 'w', encoding='utf-8') as f:
    json.dump({'uuid': user_uuid, 'public_key': public_key, 'short_id': short_id,
               'sni': sni, 'flow': 'xtls-rprx-vision'}, f, indent=2)
os.chmod(path, 0o600)
PY
  chown root:root "$CONFIG_DIR/clients/vless-reality-in.json"
  log "已生成初始 VLESS Reality 配置；连接参数保存在 $CLIENT_INFO（仅 root 可读）。"
}

write_service() {
  local temp_service
  temp_service="$(mktemp /etc/systemd/system/.sing-box.service.XXXXXX)"
  cat > "$temp_service" <<'UNIT'
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org/
Wants=network-online.target
After=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=sing-box
Group=sing-box
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576

NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectHome=true
ProtectSystem=strict
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectKernelLogs=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
RestrictRealtime=true
RestrictNamespaces=true
SystemCallArchitectures=native
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
UNIT
  if [[ "$SERVICE_NEEDS_BIND_CAP" != 'yes' ]]; then
    sed -i '/^CapabilityBoundingSet=/d; /^AmbientCapabilities=/d' "$temp_service"
  fi
  chown root:root "$temp_service"
  chmod 0644 "$temp_service"
  mv -f -- "$temp_service" "$SERVICE"
  systemctl daemon-reload
  systemd-analyze verify "$SERVICE" || die 'systemd 服务文件校验失败。'
}

install_manager() {
  install -d -o root -g root -m 0755 /usr/local/libexec
  cat > /usr/local/libexec/sing-box-manager.py <<'SB_MANAGER_EOF'
#!/usr/bin/env python3
"""Secure sing-box configuration manager installed by sing-box-install.sh."""
from __future__ import annotations
import argparse
import base64
import copy
import datetime as dt
import fcntl
import ipaddress
import json
import os
import pathlib
import re
import secrets
import shlex
import shutil
import subprocess
import sys
import tempfile
import urllib.parse
import uuid
from typing import Optional

CONFIG = pathlib.Path('/etc/sing-box/config.json')
CONFIG_DIR = CONFIG.parent
BACKUP_DIR = CONFIG_DIR / 'backups'
CERT_DIR = CONFIG_DIR / 'certs'
ACME_DIR = CONFIG_DIR / 'acme-domains'
LE_HOOK_DIR = pathlib.Path('/etc/letsencrypt/renewal-hooks/deploy')
BIN = '/usr/local/bin/sing-box'
SERVICE_USER = 'sing-box'
GROUP = 'sing-box'


def fail(message: str, code: int = 1) -> None:
    print(f'[sb] 错误：{message}', file=sys.stderr)
    raise SystemExit(code)


def run(args: list[str], *, check: bool = True, capture: bool = False, env=None):
    return subprocess.run(args, check=check, text=True,
                          stdout=subprocess.PIPE if capture else None,
                          stderr=subprocess.PIPE if capture else None, env=env)


def require_root() -> None:
    if os.geteuid() != 0:
        fail('请使用 sudo 运行配置修改命令。')


def read_config() -> dict:
    try:
        with CONFIG.open(encoding='utf-8') as f:
            data = json.load(f)
    except Exception as exc:
        fail(f'读取配置失败：{exc}')
    if not isinstance(data, dict) or not isinstance(data.get('inbounds'), list):
        fail('配置结构异常，未作修改。')
    return data


def find_inbound(data: dict, selector: str) -> dict:
    matches = [i for i in data['inbounds']
               if i.get('tag') == selector or str(i.get('listen_port', '')) == selector]
    if len(matches) != 1:
        fail('名称/端口必须精确匹配且只命中一个入站；可先运行 sb info。')
    return matches[0]


def save_config(data: dict) -> None:
    require_root()
    CONFIG_DIR.mkdir(mode=0o750, parents=True, exist_ok=True)
    if CONFIG.is_symlink():
        fail('拒绝写入符号链接配置。')
    BACKUP_DIR.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chown(BACKUP_DIR, 0, 0)
    os.chmod(BACKUP_DIR, 0o700)
    stamp = dt.datetime.now(dt.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    backup = BACKUP_DIR / f'config-{stamp}-{secrets.token_hex(3)}.json'
    if CONFIG.exists():
        shutil.copy2(CONFIG, backup)
        os.chmod(backup, 0o600)
    fd, tmp_name = tempfile.mkstemp(prefix='.config.', dir=CONFIG_DIR)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
            f.write('\n')
            f.flush()
            os.fsync(f.fileno())
        os.chown(tmp_name, 0, grp_id())
        os.chmod(tmp_name, 0o640)
        run([BIN, 'check', '-c', tmp_name])
        os.replace(tmp_name, CONFIG)
        # Keep a bounded backup history.
        backups = sorted(BACKUP_DIR.glob('config-*.json'), key=lambda p: p.stat().st_mtime, reverse=True)
        for old in backups[20:]:
            old.unlink(missing_ok=True)
        restarted = run(['systemctl', 'restart', 'sing-box.service'], check=False)
        active = run(['systemctl', 'is-active', '--quiet', 'sing-box.service'], check=False)
        if restarted.returncode != 0 or active.returncode != 0:
            if backup.exists():
                shutil.copy2(backup, CONFIG)
                os.chown(CONFIG, 0, grp_id())
                os.chmod(CONFIG, 0o640)
                run(['systemctl', 'restart', 'sing-box.service'], check=False)
            fail(f'新配置启动失败，已恢复旧配置。详情：journalctl -u sing-box -n 60')
        print(f'[sb] 已更新配置；备份：{backup}')
    finally:
        pathlib.Path(tmp_name).unlink(missing_ok=True)


def grp_id() -> int:
    import grp
    try:
        return grp.getgrnam(GROUP).gr_gid
    except KeyError:
        fail('缺少 sing-box 系统组；请先运行安装器。')


def random_password() -> str:
    return secrets.token_urlsafe(24)


def random_ss_key(method: str) -> str:
    lengths = {'2022-blake3-aes-128-gcm': 16,
               '2022-blake3-aes-256-gcm': 32,
               '2022-blake3-chacha20-poly1305': 32}
    if method in lengths:
        return run([BIN, 'generate', 'rand', '--base64', str(lengths[method])], capture=True).stdout.strip()
    return random_password()


def reality_keys() -> tuple[str, str]:
    result = run([BIN, 'generate', 'reality-keypair'], capture=True).stdout
    private = re.search(r'PrivateKey:\s*(\S+)', result)
    public = re.search(r'PublicKey:\s*(\S+)', result)
    if not private or not public:
        fail('无法解析 Reality 密钥。')
    return private.group(1), public.group(1)


def check_port(port: int, data: dict, skip_tag: Optional[str] = None) -> None:
    if not 1 <= port <= 65535:
        fail('端口必须在 1 到 65535 之间。')
    used = [i for i in data.get('inbounds', []) if int(i.get('listen_port', 0)) == port and i.get('tag') != skip_tag]
    if used:
        fail(f'端口 {port} 已被入站 {used[0].get("tag", "?")} 使用。')


def require_tls_args(args) -> dict:
    if getattr(args, 'acme', False):
        domain = _acme_domain(args.domain or args.sni or '')
        cert = CERT_DIR / domain / 'fullchain.pem'
        key = CERT_DIR / domain / 'privkey.pem'
        if not cert.is_file() or not key.is_file():
            fail(f'找不到 {domain} 的 ACME 证书；先运行 sb acme issue --domain {domain} --email EMAIL。')
        for path in (cert, key):
            result = run(['runuser', '-u', SERVICE_USER, '--', 'test', '-r', str(path)], check=False)
            if result.returncode: fail(f'{path} 对 sing-box 服务用户不可读。')
        return {'enabled': True, 'certificate_path': str(cert), 'key_path': str(key),
                'min_version': '1.2', 'server_name': domain}
    if not args.cert or not args.key:
        fail('TLS 入站必须提供 --cert 与 --key。脚本不会自动申请证书。')
    if not (args.domain or args.sni):
        fail('TLS 入站必须指定 --domain 或 --sni，确保客户端 SNI 与证书域名匹配。')
    cert, key = pathlib.Path(args.cert), pathlib.Path(args.key)
    if not cert.is_absolute() or not key.is_absolute() or not cert.is_file() or not key.is_file():
        fail('证书和私钥必须是存在的绝对路径。')
    # The daemon runs unprivileged; reject credentials it cannot read.
    for path in (cert, key):
        result = run(['runuser', '-u', SERVICE_USER, '--', 'test', '-r', str(path)], check=False)
        if result.returncode:
            fail(f'{path} 对 sing-box 服务用户不可读；请谨慎配置组权限后重试。')
    return {'enabled': True, 'certificate_path': str(cert), 'key_path': str(key),
            'min_version': '1.2'}


def _acme_domain(value: str) -> str:
    domain = value.lower().rstrip('.')
    try: ipaddress.ip_address(domain); is_ip = True
    except ValueError: is_ip = False
    if '.' not in domain or is_ip or not re.fullmatch(r'(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)(?:\.(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?))*', domain):
        fail('域名格式无效；HTTP-01 仅支持公开 DNS 域名，不支持 IP 或通配符。')
    return domain


def install_acme_hook(domain: str, cert_name: str) -> pathlib.Path:
    LE_HOOK_DIR.mkdir(mode=0o755, parents=True, exist_ok=True)
    hook = LE_HOOK_DIR / f'sing-box-{domain}.sh'
    certbot_lineage = f'/etc/letsencrypt/live/{cert_name}'
    target = CERT_DIR / domain
    script = f'''#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
expected_lineage={shlex.quote(certbot_lineage)}
target={shlex.quote(str(target))}
[[ "${{RENEWED_LINEAGE:-}}" == "$expected_lineage" ]] || exit 0
install -d -o root -g {shlex.quote(GROUP)} -m 0750 "$(dirname "$target")"
stage="$(mktemp -d "$(dirname "$target")/.stage.XXXXXX")"
backup="$(mktemp -d "$(dirname "$target")/.backup.XXXXXX")"
cleanup() {{ rm -rf -- "$stage"; }}
trap cleanup EXIT
install -o root -g {shlex.quote(GROUP)} -m 0640 "$RENEWED_LINEAGE/fullchain.pem" "$stage/fullchain.pem"
install -o root -g {shlex.quote(GROUP)} -m 0640 "$RENEWED_LINEAGE/privkey.pem" "$stage/privkey.pem"
chown root:{shlex.quote(GROUP)} "$stage"
chmod 0750 "$stage"
if [[ -d "$target" ]]; then cp -a -- "$target/." "$backup/"; fi
rm -rf -- "$target"
mv -- "$stage" "$target"
if {shlex.quote(BIN)} check -c {shlex.quote(str(CONFIG))} && systemctl restart sing-box.service && systemctl is-active --quiet sing-box.service; then
  rm -rf -- "$backup"
  trap - EXIT
  exit 0
fi
rm -rf -- "$target"
if [[ -n "$(find "$backup" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then chown root:{shlex.quote(GROUP)} "$backup"; chmod 0750 "$backup"; mv -- "$backup" "$target"; else rm -rf -- "$backup"; fi
systemctl restart sing-box.service || true
echo 'sing-box ACME deploy failed; previous certificate files were restored.' >&2
exit 1
'''
    fd, temp = tempfile.mkstemp(prefix='.hook.', dir=LE_HOOK_DIR)
    with os.fdopen(fd, 'w', encoding='utf-8') as f: f.write(script)
    os.chown(temp, 0, 0); os.chmod(temp, 0o755)
    os.replace(temp, hook)
    return hook


def acme_cmd(args) -> None:
    require_root()
    if args.acme_action == 'renew':
        certbot = shutil.which('certbot')
        if not certbot: fail('Certbot 未安装；先运行 sb acme issue。')
        run([certbot, 'renew', '--quiet'])
        return
    if args.acme_action == 'status':
        certbot = shutil.which('certbot')
        if not certbot: fail('Certbot 未安装；先运行 sb acme issue。')
        run([certbot, 'certificates'], check=False)
        run(['systemctl', '--no-pager', 'list-timers', 'certbot.timer', 'sing-box-certbot-renew.timer'], check=False)
        return
    domain = _acme_domain(args.domain)
    email = args.email
    if not re.fullmatch(r'[^\s@]+@[^\s@]+\.[^\s@]+', email): fail('邮箱地址格式无效。')
    cert_name = f'sing-box-{domain}'
    certbot = shutil.which('certbot')
    if not certbot:
        print('[sb] 安装 Certbot（只安装证书客户端，不更改现有 Web 服务）。')
        run(['apt-get', 'update'])
        run(['apt-get', 'install', '-y', '--no-install-recommends', 'certbot'])
        certbot = shutil.which('certbot')
        if not certbot: fail('Certbot 安装后仍不可用。')
    registry = ACME_DIR / f'{domain}.json'
    cert_name_path = pathlib.Path('/etc/letsencrypt/live') / cert_name
    if cert_name_path.exists() and not registry.exists():
        fail(f'Certbot 已有 lineage {cert_name}，但不是本管理器登记的证书；为防覆盖停止操作。')
    ACME_DIR.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chown(ACME_DIR, 0, 0); os.chmod(ACME_DIR, 0o700)
    old_registry = registry.read_bytes() if registry.exists() else None
    registry.write_text(json.dumps({'domain': domain, 'cert_name': cert_name}, indent=2), encoding='utf-8')
    os.chown(registry, 0, 0); os.chmod(registry, 0o600)
    hook = install_acme_hook(domain, cert_name)
    try:
        if args.webroot:
            webroot = pathlib.Path(args.webroot)
            if not webroot.is_absolute() or not webroot.is_dir(): fail('--webroot 必须是服务器上已配置 HTTP 服务的绝对目录。')
            challenge_args = ['--webroot', '-w', str(webroot)]
        else:
            challenge_args = ['--standalone']
        run([certbot, 'certonly', *challenge_args, '--preferred-challenges', 'http',
             '--cert-name', cert_name, '-d', domain, '--email', email,
             '--agree-tos', '--no-eff-email', '--non-interactive'])
        lineage = f'/etc/letsencrypt/live/{cert_name}'
        env = os.environ.copy(); env['RENEWED_LINEAGE'] = lineage; env['RENEWED_DOMAINS'] = domain
        run([str(hook)], check=True, env=env)
        CERT_DIR.mkdir(mode=0o750, parents=True, exist_ok=True)
        cert_file = CERT_DIR / domain / 'fullchain.pem'
        key_file = CERT_DIR / domain / 'privkey.pem'
        if not cert_file.is_file() or not key_file.is_file(): fail('Certbot 签发成功，但部署钩子未安装证书。')
        # Debian/Ubuntu packages provide a timer; create a fallback if they do not.
        listed = run(['systemctl', 'list-unit-files', 'certbot.timer', '--no-legend'], check=False, capture=True)
        timer_enabled = False
        if listed.returncode == 0 and 'certbot.timer' in listed.stdout:
            timer_enabled = run(['systemctl', 'enable', '--now', 'certbot.timer'], check=False).returncode == 0
        if not timer_enabled:
            timer_service = pathlib.Path('/etc/systemd/system/sing-box-certbot-renew.service')
            timer_unit = pathlib.Path('/etc/systemd/system/sing-box-certbot-renew.timer')
            timer_service.write_text(f'[Unit]\nDescription=Renew ACME certificates\n[Service]\nType=oneshot\nExecStart={certbot} renew --quiet\n', encoding='utf-8')
            timer_unit.write_text('[Unit]\nDescription=Daily ACME renewal check\n[Timer]\nOnCalendar=*-*-* 03,15:00:00\nRandomizedDelaySec=1h\nPersistent=true\n[Install]\nWantedBy=timers.target\n', encoding='ascii')
            os.chmod(timer_service, 0o644); os.chmod(timer_unit, 0o644)
            run(['systemctl', 'daemon-reload']); run(['systemctl', 'enable', '--now', 'sing-box-certbot-renew.timer'])
        print(f'[sb] ACME 证书已就绪并配置自动续期：{cert_file}')
        print(f'[sb] 新建 TLS 入站时使用 --domain {domain} --acme。')
        if args.webroot:
            print(f'[sb] HTTP-01 需要公网 TCP/80 可达，并确保 Web 服务将挑战目录映射到 {args.webroot}。')
        else:
            print('[sb] HTTP-01 需要公网 TCP/80 可达且签发期间端口 80 空闲；脚本不会修改防火墙。')
    except BaseException:
        if not cert_name_path.exists():
            if old_registry is None: registry.unlink(missing_ok=True)
            else: registry.write_bytes(old_registry)
            if old_registry is None: hook.unlink(missing_ok=True)
        else:
            print('[sb] Certbot lineage 保留；部署或定时器设置未完成，可运行 sb acme issue 再次配置。', file=sys.stderr)
        raise


def make_inbound(args, data: dict) -> dict:
    proto = args.protocol.lower()
    proto = {'r': 'reality', 'hy': 'hysteria2', 'hy2': 'hysteria2',
             'tcp': 'vmess', 'ws': 'vmess-ws-clear', 'wss': 'vmess-ws',
             'vws': 'vless-ws', 'tws': 'trojan-ws',
             'h2': 'vmess-http', 'hu': 'vmess-httpupgrade',
             'http': 'vmess-http-clear', 'quic': 'vmess-quic-clear',
             'vh2': 'vless-http', 'vhu': 'vless-httpupgrade',
             'th2': 'trojan-http', 'thu': 'trojan-httpupgrade'}.get(proto, proto)
    port = args.port
    if port is None:
        port = 8443
        while any(int(i.get('listen_port', 0)) == port for i in data.get('inbounds', [])):
            port = 20000 + secrets.randbelow(40000)
        args.port = port
    check_port(port, data)
    tag = f'{proto}-{port}'
    inbound: dict = {'type': proto, 'tag': tag, 'listen': '::', 'listen_port': port}
    username = args.username or 'user'
    password = args.password or random_password()
    user_uuid = args.uuid or str(uuid.uuid4())
    sni = args.sni or args.domain

    if proto in ('reality', 'vless-reality'):
        private, public = reality_keys()
        sid = secrets.token_hex(8)
        server_name = sni or 'www.cloudflare.com'
        inbound.update({'type': 'vless', 'users': [{'name': username, 'uuid': user_uuid,
                                                    'flow': 'xtls-rprx-vision'}],
          'tls': {'enabled': True, 'server_name': server_name,
                  'reality': {'enabled': True,
                    'handshake': {'server': server_name, 'server_port': 443},
                    'private_key': private, 'short_id': [sid]}}})
        inbound['_client'] = {'uuid': user_uuid, 'public_key': public, 'short_id': sid,
                              'sni': server_name, 'flow': 'xtls-rprx-vision'}
    elif proto in ('ss', 'shadowsocks'):
        method = args.method or '2022-blake3-aes-128-gcm'
        inbound.update({'type': 'shadowsocks', 'method': method,
                        'password': args.password or random_ss_key(method)})
    elif proto in ('socks', 'socks5'):
        inbound.update({'type': 'socks', 'users': [{'username': username, 'password': password}]})
    elif proto in ('vmess', 'vless'):
        inbound.update({'type': proto, 'users': [{'name': username, 'uuid': user_uuid}]})
    elif proto in ('vmess-ws', 'vmess-ws-clear', 'vless-ws', 'trojan-ws',
                   'vmess-http', 'vless-http', 'trojan-http',
                   'vmess-quic', 'vless-quic',
                   'vmess-httpupgrade', 'vless-httpupgrade', 'trojan-httpupgrade',
                   'vmess-http-clear', 'vmess-quic-clear'):
        clear_transport = proto in ('vmess-ws-clear', 'vmess-http-clear', 'vmess-quic-clear')
        tls = {} if clear_transport else require_tls_args(args)
        if tls: tls['server_name'] = args.domain or args.sni or ''
        base_proto = proto[:-6] if proto.endswith('-clear') else proto
        transport_type = base_proto.rsplit('-', 1)[1]
        if transport_type == 'httpupgrade': transport_type = 'httpupgrade'
        elif transport_type == 'http': transport_type = 'http'
        elif transport_type == 'quic': transport_type = 'quic'
        else: transport_type = 'ws'
        inbound.update({'type': proto.split('-')[0], 'users': ([{'name': username, 'uuid': user_uuid}]
                         if proto.startswith(('vmess', 'vless')) else [{'name': username, 'password': password}]),
                        'transport': {'type': transport_type, 'path': args.path or '/ws'}})
        if tls: inbound['tls'] = tls
    elif proto in ('trojan', 'anytls', 'tuic', 'hysteria2'):
        tls = require_tls_args(args)
        tls['server_name'] = args.domain or args.sni or ''
        if proto == 'trojan':
            inbound.update({'users': [{'name': username, 'password': password}], 'tls': tls})
        elif proto == 'anytls':
            inbound.update({'users': [{'name': username, 'password': password}], 'tls': tls})
        elif proto == 'tuic':
            inbound.update({'users': [{'name': username, 'uuid': user_uuid, 'password': password}],
                            'congestion_control': 'cubic', 'zero_rtt_handshake': False,
                            'tls': tls})
        else:
            obfs_password = random_password()
            inbound.update({'users': [{'name': username, 'password': password}], 'tls': tls,
                            'obfs': {'type': 'salamander', 'password': obfs_password}})
    else:
        fail('协议需选 reality、ss、socks、vmess、vless、trojan、anytls、tuic、hysteria2 或支持的传输变体。')
    inbound['_generated'] = {'username': username, 'password': password, 'uuid': user_uuid,
                             'method': inbound.get('method', args.method or '2022-blake3-aes-128-gcm'),
                             'server_name': sni or args.domain or '',
                             'obfs_password': inbound.get('obfs', {}).get('password', '')}
    return inbound


def clean_internal(inbound: dict) -> dict:
    return {k: v for k, v in inbound.items() if not k.startswith('_')}


def add_cmd(args) -> None:
    require_root()
    with open('/run/lock/sing-box-manager.lock', 'w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        data = read_config()
        inbound = make_inbound(args, data)
        if args.dry_run:
            print(json.dumps(clean_internal(inbound), ensure_ascii=False, indent=2))
            return
        data.setdefault('inbounds', []).append(clean_internal(inbound))
        save_config(data)
        if inbound.get('_client'):
            clients = CONFIG_DIR / 'clients'
            clients.mkdir(mode=0o700, exist_ok=True)
            client_file = clients / f'{inbound["tag"]}.json'
            client_file.write_text(json.dumps(inbound['_client'], indent=2), encoding='utf-8')
            os.chown(client_file, 0, grp_id())
            os.chmod(client_file, 0o600)
        print_client(args, inbound)


def print_client(args, inbound: dict) -> None:
    proto, port, host = args.protocol.lower(), args.port, args.server or '<SERVER_IP_OR_DOMAIN>'
    info = inbound.get('_generated', {})
    client = inbound.get('_client', {})
    print('\n客户端参数（含密钥，请勿公开）：')
    print(f'协议：{inbound["type"]}\n服务器：{host}\n端口：{port}\n名称：{inbound["tag"]}')
    if client:
        query = urllib.parse.urlencode({'type': 'tcp', 'security': 'reality', 'pbk': client['public_key'],
              'fp': 'chrome', 'sni': client['sni'], 'sid': client['short_id'], 'flow': client['flow']})
        print(f'UUID：{client["uuid"]}')
        print(f'分享链接：vless://{client["uuid"]}@{host}:{port}?{query}#{inbound["tag"]}')
    else:
        if 'uuid' in info: print(f'UUID：{info["uuid"]}')
        if 'username' in info: print(f'用户名：{info["username"]}')
        if 'password' in info: print(f'密码/密钥：{info["password"]}')
        if 'method' in info: print(f'加密：{inbound.get("method", info["method"])}')
        if info.get('obfs_password'): print(f'混淆密码：{info["obfs_password"]}')
        if inbound.get('tls'): print(f'TLS：{inbound["tls"].get("certificate_path")}')


def info_cmd(args) -> None:
    data = read_config()
    entries = data.get('inbounds', [])
    if args.name:
        entries = [find_inbound(data, args.name)]
    if not entries:
        print('没有入站配置。'); return
    for i in entries:
        print(f'{i.get("tag", "?")}  type={i.get("type", "?")}  listen={i.get("listen", "?")}:{i.get("listen_port", "?")}')
        tls = i.get('tls', {})
        if tls.get('reality', {}).get('enabled'): print(f'  Reality SNI={tls.get("server_name", "")}')
        elif tls.get('enabled'): print(f'  TLS cert={tls.get("certificate_path", "configured")}')
        if i.get('transport'): print(f'  transport={i["transport"].get("type")} path={i["transport"].get("path", "")}')


def del_cmd(args) -> None:
    require_root()
    data = read_config()
    item = find_inbound(data, args.name)
    if not args.yes:
        answer = input(f'确认删除入站 {item["tag"]}？输入 DELETE：')
        if answer != 'DELETE': fail('已取消。', 0)
    data['inbounds'] = [i for i in data['inbounds'] if i is not item]
    save_config(data)
    sidecar = CONFIG_DIR / 'clients' / f'{item.get("tag")}.json'
    sidecar.unlink(missing_ok=True)


def change_cmd(args) -> None:
    require_root()
    data = read_config()
    item = find_inbound(data, args.name)
    old_tag = item.get('tag')
    sidecar_sni = None
    if args.port is not None:
        check_port(args.port, data, skip_tag=item.get('tag'))
        item['listen_port'] = args.port
        item['tag'] = re.sub(r'-\d+$', f'-{args.port}', item.get('tag', 'inbound'))
    if args.uuid:
        users = item.get('users', [])
        if not users: fail('此入站没有可编辑的用户。')
        users[0]['uuid'] = args.uuid
    if args.method:
        if item.get('type') != 'shadowsocks': fail('--method 仅适用于 Shadowsocks。')
        item['method'] = args.method
        item['password'] = random_ss_key(args.method)
    if args.password:
        users = item.get('users', [])
        if item.get('type') == 'shadowsocks': item['password'] = args.password
        elif item.get('type') in ('trojan', 'anytls', 'tuic', 'hysteria2', 'socks') and users:
            users[0]['password'] = args.password
        else: fail('此入站没有可编辑的密码。')
    if args.sni:
        tls = item.setdefault('tls', {})
        if tls.get('reality', {}).get('enabled'):
            tls['server_name'] = args.sni
            tls['reality']['handshake']['server'] = args.sni
            sidecar_sni = args.sni
        else: fail('当前只支持修改 Reality SNI；普通 TLS 需更新证书配置。')
    if args.path:
        transport = item.setdefault('transport', {})
        if transport.get('type') not in ('ws', 'http', 'httpupgrade'):
            fail('此入站没有可修改的 Web 传输路径。')
        transport['path'] = args.path
    new_reality_pair = None
    if args.rotate_key:
        tls = item.get('tls', {})
        if not tls.get('reality', {}).get('enabled'): fail('--rotate-key 仅适用于 Reality。')
        new_reality_pair = reality_keys()
        tls['reality']['private_key'] = new_reality_pair[0]
    save_config(data)
    if old_tag != item.get('tag'):
        old_sidecar = CONFIG_DIR / 'clients' / f'{old_tag}.json'
        new_sidecar = CONFIG_DIR / 'clients' / f'{item.get("tag")}.json'
        if old_sidecar.is_file(): old_sidecar.replace(new_sidecar)
    if sidecar_sni:
        sidecar = CONFIG_DIR / 'clients' / f'{item.get("tag")}.json'
        if sidecar.is_file():
            client = json.loads(sidecar.read_text(encoding='utf-8'))
            client['sni'] = sidecar_sni
            sidecar.write_text(json.dumps(client, indent=2), encoding='utf-8')
            os.chown(sidecar, 0, grp_id()); os.chmod(sidecar, 0o600)
    if new_reality_pair:
        sidecar = CONFIG_DIR / 'clients' / f'{item.get("tag")}.json'
        if sidecar.is_file():
            client = json.loads(sidecar.read_text(encoding='utf-8'))
            client['public_key'] = new_reality_pair[1]
            sidecar.write_text(json.dumps(client, indent=2), encoding='utf-8')
            os.chown(sidecar, 0, grp_id()); os.chmod(sidecar, 0o600)


def xray_inbound_to_sing(inbound: dict) -> dict:
    protocol = str(inbound.get('protocol', '')).lower()
    settings = inbound.get('settings') or {}
    stream = inbound.get('streamSettings') or {}
    if not isinstance(settings, dict) or not isinstance(stream, dict): fail('Xray/V2Ray inbound settings 结构无效。')
    sniffing = inbound.get('sniffing') or {}
    if not isinstance(sniffing, dict): fail('Xray/V2Ray sniffing 字段结构无效。')
    if sniffing.get('enabled'):
        fail('Xray/V2Ray inbound 启用了 sniffing；导入器不迁移其路由行为，请先关闭或手动迁移。')
    if stream.get('sockopt'):
        fail('Xray/V2Ray inbound 配置了 sockopt；请先手动迁移 socket 选项。')
    try: port = int(inbound.get('port'))
    except (TypeError, ValueError): fail('Xray/V2Ray inbound 端口必须是单一整数。')
    if not 1 <= port <= 65535: fail(f'Xray/V2Ray inbound 端口无效：{port}')
    listen = inbound.get('listen') or '::'
    tag = inbound.get('tag') or f'{protocol}-{port}'
    if not isinstance(tag, str) or not re.fullmatch(r'[A-Za-z0-9_.-]{1,64}', tag): fail('导入 tag 含有不支持的字符。')
    result = {'type': protocol, 'tag': tag, 'listen': listen, 'listen_port': port}

    if protocol == 'vmess':
        clients = settings.get('clients') or []
        if not clients: fail(f'{tag}: VMess 没有 clients。')
        users = []
        for client in clients:
            if not isinstance(client, dict) or not client.get('id'): fail(f'{tag}: VMess client 缺少 id。')
            try: alter_id = int(client.get('alterId', 0) or 0)
            except (TypeError, ValueError): fail(f'{tag}: VMess alterId 无效。')
            if alter_id != 0: fail(f'{tag}: 仅支持 VMess AEAD（alterId=0）。')
            users.append({'name': client.get('email') or f'user{len(users)+1}', 'uuid': client['id']})
        result['users'] = users
    elif protocol == 'vless':
        decryption = settings.get('decryption', 'none')
        if decryption not in ('none', ''): fail(f'{tag}: 不支持 VLESS decryption={decryption}。')
        clients = settings.get('clients') or []
        if not clients: fail(f'{tag}: VLESS 没有 clients。')
        result['users'] = []
        for client in clients:
            if not isinstance(client, dict) or not client.get('id'): fail(f'{tag}: VLESS client 缺少 id。')
            flow = client.get('flow', '')
            if flow not in ('', 'xtls-rprx-vision'): fail(f'{tag}: 不支持 VLESS flow={flow}。')
            user = {'name': client.get('email') or f'user{len(result["users"])+1}', 'uuid': client['id']}
            if flow: user['flow'] = flow
            result['users'].append(user)
    elif protocol == 'trojan':
        clients = settings.get('clients') or []
        if not clients: fail(f'{tag}: Trojan 没有 clients。')
        if not all(isinstance(c, dict) and c.get('password') for c in clients): fail(f'{tag}: Trojan client 缺少 password。')
        result['users'] = [{'name': c.get('email') or f'user{i+1}', 'password': c['password']}
                           for i, c in enumerate(clients)]
        if settings.get('fallbacks'): fail(f'{tag}: Trojan fallbacks 需手动转换，未导入。')
    elif protocol == 'shadowsocks':
        if not settings.get('method') or not settings.get('password'):
            fail(f'{tag}: 仅支持单密码 Shadowsocks 入站。')
        result.update({'type': 'shadowsocks', 'method': settings['method'], 'password': settings['password']})
        if settings.get('network') not in (None, '', 'tcp,udp', 'tcp, udp'):
            fail(f'{tag}: Shadowsocks network 限制需手动复核。')
    elif protocol in ('socks', 'http'):
        auth = settings.get('auth', 'noauth')
        accounts = settings.get('accounts') or []
        if accounts and not all(isinstance(a, dict) and 'user' in a and 'pass' in a for a in accounts):
            fail(f'{tag}: {protocol} accounts 字段无效。')
        if auth == 'password' and not accounts: fail(f'{tag}: {protocol} 密码认证没有 accounts。')
        if auth not in ('noauth', 'password'): fail(f'{tag}: 不支持 {protocol} auth={auth}。')
        if accounts:
            result['users'] = [{'username': a['user'], 'password': a['pass']} for a in accounts]
    else:
        fail(f'{tag}: 暂不支持 Xray/V2Ray protocol={protocol}。')

    network = stream.get('network', 'tcp')
    security = stream.get('security', 'none')
    transport_settings = stream.get(f'{network}Settings') or {}
    if not isinstance(transport_settings, dict): fail(f'{tag}: transport settings 必须是对象。')
    if network == 'tcp':
        header_type = (transport_settings.get('header') or {}).get('type', 'none')
        if header_type not in ('none', ''): fail(f'{tag}: TCP header camouflage 需手动转换。')
    elif network == 'ws':
        headers = transport_settings.get('headers') or {}
        if headers: fail(f'{tag}: WS 自定义 headers 未自动映射，请用 sb edit 手动复核。')
        result['transport'] = {'type': 'ws', 'path': transport_settings.get('path') or '/'}
    elif network == 'http':
        result['transport'] = {'type': 'http', 'path': transport_settings.get('path') or '/'}
        hosts = transport_settings.get('host') or []
        if hosts: result['transport']['host'] = hosts if isinstance(hosts, list) else [hosts]
    elif network == 'httpupgrade':
        result['transport'] = {'type': 'httpupgrade', 'path': transport_settings.get('path') or '/',
                               'host': transport_settings.get('host', '')}
    elif network == 'grpc':
        result['transport'] = {'type': 'grpc', 'service_name': transport_settings.get('serviceName', '')}
    elif network == 'quic':
        quic_header = (transport_settings.get('header') or {}).get('type', 'none')
        if quic_header not in ('none', ''): fail(f'{tag}: QUIC header camouflage 需手动转换。')
        result['transport'] = {'type': 'quic'}
    else:
        fail(f'{tag}: 不支持传输 network={network}。')

    if security == 'tls':
        tls_settings = stream.get('tlsSettings') or {}
        certificates = tls_settings.get('certificates') or []
        if len(certificates) != 1: fail(f'{tag}: TLS 必须恰好配置一组证书/私钥路径。')
        if not isinstance(certificates[0], dict): fail(f'{tag}: TLS certificate 条目结构无效。')
        cert = pathlib.Path(certificates[0].get('certificateFile', ''))
        key = pathlib.Path(certificates[0].get('keyFile', ''))
        if ACME_DIR.is_dir():
            for metadata in ACME_DIR.glob('*.json'):
                try:
                    managed = json.loads(metadata.read_text(encoding='utf-8'))
                    lineage = pathlib.Path('/etc/letsencrypt/live') / managed['cert_name']
                    if cert == lineage / 'fullchain.pem' and key == lineage / 'privkey.pem':
                        cert = CERT_DIR / managed['domain'] / 'fullchain.pem'
                        key = CERT_DIR / managed['domain'] / 'privkey.pem'
                        break
                except (OSError, ValueError, KeyError, TypeError):
                    continue
        if not cert.is_absolute() or not key.is_absolute() or not cert.is_file() or not key.is_file():
            fail(f'{tag}: TLS cert/key 必须是现存的绝对文件路径。')
        for path in (cert, key):
            if run(['runuser', '-u', SERVICE_USER, '--', 'test', '-r', str(path)], check=False).returncode:
                fail(f'{tag}: {path} 对 sing-box 服务用户不可读。')
        tls = {'enabled': True, 'certificate_path': str(cert), 'key_path': str(key)}
        if tls_settings.get('serverName'): tls['server_name'] = tls_settings['serverName']
        if tls_settings.get('alpn'): tls['alpn'] = tls_settings['alpn']
        if tls_settings.get('minVersion'):
            min_version = str(tls_settings['minVersion'])
            tls['min_version'] = min_version[4:] if min_version.startswith('TLS ') else min_version
        result['tls'] = tls
    elif security == 'reality':
        if protocol != 'vless': fail(f'{tag}: Reality 仅支持 VLESS。')
        reality = stream.get('realitySettings') or {}
        private = reality.get('privateKey')
        names = reality.get('serverNames') or []
        short_ids = reality.get('shortIds') or []
        dest = str(reality.get('dest') or '')
        if not private or not names or not short_ids or ':' not in dest:
            fail(f'{tag}: Reality 缺少 privateKey/serverNames/shortIds/dest。')
        if any(not isinstance(sid, str) or not re.fullmatch(r'[0-9a-fA-F]{0,8}', sid) for sid in short_ids):
            fail(f'{tag}: Reality shortIds 必须是 0 到 8 位十六进制字符串。')
        dest_host, dest_port = dest.rsplit(':', 1)
        try: dest_port = int(dest_port)
        except ValueError: fail(f'{tag}: Reality dest 端口无效。')
        result['tls'] = {'enabled': True, 'server_name': names[0],
                         'reality': {'enabled': True,
                           'handshake': {'server': dest_host.strip('[]'), 'server_port': dest_port},
                           'private_key': private, 'short_id': short_ids}}
        openssl = shutil.which('openssl')
        if not openssl: fail(f'{tag}: 导入 Reality 需要系统 openssl 来推导客户端公钥。')
        try:
            raw_private = base64.urlsafe_b64decode(private + '=' * (-len(private) % 4))
            der_private = bytes.fromhex('302e020100300506032b656e04220420') + raw_private
            pub_der = subprocess.run([openssl, 'pkey', '-inform', 'DER', '-pubout', '-outform', 'DER'],
                                     input=der_private, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                     check=True).stdout
            public = base64.urlsafe_b64encode(pub_der[-32:]).decode().rstrip('=')
        except Exception as exc:
            fail(f'{tag}: 无法从 Reality 私钥推导公钥：{exc}')
        result['_client'] = {'uuid': result['users'][0]['uuid'], 'public_key': public,
                             'short_id': short_ids[0], 'sni': names[0],
                             'flow': result['users'][0].get('flow', '')}
    elif security not in ('', 'none'):
        fail(f'{tag}: 不支持 security={security}。')
    return result


def import_cmd(args) -> None:
    require_root()
    source = pathlib.Path(args.file)
    if source.is_symlink() or not source.is_file(): fail('导入源必须是普通 JSON 配置文件。')
    try:
        incoming = json.loads(source.read_text(encoding='utf-8'))
        imported = incoming['inbounds']
        if not isinstance(imported, list) or not imported: fail('导入文件中没有 inbounds。')
    except (OSError, ValueError, KeyError, TypeError) as exc:
        fail(f'读取导入配置失败：{exc}')
    if not all(isinstance(i, dict) for i in imported): fail('导入文件的 inbounds 必须全部为 JSON 对象。')
    sidecars = {}
    converted = []
    for item in imported:
        converted_item = xray_inbound_to_sing(item) if 'protocol' in item else item
        sidecar = converted_item.pop('_client', None)
        if sidecar: sidecars[converted_item.get('tag')] = sidecar
        converted.append(converted_item)
    imported = converted
    data = read_config()
    existing_tags = {i.get('tag') for i in data.get('inbounds', [])}
    existing_ports = {int(i.get('listen_port', 0)) for i in data.get('inbounds', [])}
    for item in imported:
        if not isinstance(item, dict) or not isinstance(item.get('type'), str): fail('导入配置含有无效入站。')
        try: port = int(item.get('listen_port', 0))
        except (TypeError, ValueError): fail('导入配置含有无效监听端口。')
        if not 1 <= port <= 65535 or port in existing_ports: fail(f'导入入站端口无效或冲突：{port}')
        tag = item.get('tag')
        if not tag or tag in existing_tags: fail(f'导入入站 tag 缺失或冲突：{tag}')
        existing_ports.add(port); existing_tags.add(tag)
    if not args.yes:
        for item in imported:
            print(f'  {item.get("tag", "?")}  type={item.get("type", "?")}  port={item.get("listen_port", "?")}')
        answer = input(f'将导入 {len(imported)} 个 sing-box 入站并重启服务。输入 IMPORT：')
        if answer != 'IMPORT': fail('已取消。', 0)
    data['inbounds'].extend(imported)
    save_config(data)
    if sidecars:
        client_dir = CONFIG_DIR / 'clients'
        client_dir.mkdir(mode=0o700, exist_ok=True)
        for tag, client in sidecars.items():
            target = client_dir / f'{tag}.json'
            target.write_text(json.dumps(client, indent=2), encoding='utf-8')
            os.chown(target, 0, grp_id()); os.chmod(target, 0o600)


def edit_cmd(args) -> None:
    require_root()
    fd, temp_name = tempfile.mkstemp(prefix='.edit.', suffix='.json', dir=CONFIG_DIR)
    os.close(fd)
    try:
        shutil.copy2(CONFIG, temp_name)
        os.chown(temp_name, 0, grp_id()); os.chmod(temp_name, 0o640)
        editor = shlex.split(os.environ.get('EDITOR', 'vi'))
        if not editor or not shutil.which(editor[0]): fail('找不到编辑器；设置 EDITOR 后重试。')
        run([*editor, temp_name])
        with open(temp_name, encoding='utf-8') as f:
            data = json.load(f)
        if not isinstance(data, dict) or not isinstance(data.get('inbounds'), list):
            fail('编辑后的 JSON 配置结构无效。')
        save_config(data)
    except (OSError, ValueError) as exc:
        fail(f'读取编辑结果失败：{exc}')
    finally:
        pathlib.Path(temp_name).unlink(missing_ok=True)


def share_uri(item: dict, host: str) -> str:
    proto, port = item.get('type'), int(item.get('listen_port', 0))
    user = (item.get('users') or [{}])[0]
    tls = item.get('tls', {})
    transport = item.get('transport', {})
    name = urllib.parse.quote(item.get('tag', 'sing-box'), safe='')
    if tls.get('reality', {}).get('enabled'):
        sidecar = CONFIG_DIR / 'clients' / f'{item.get("tag")}.json'
        if not sidecar.is_file(): fail(f'Reality 客户端公钥文件缺失：{sidecar}')
        client = json.loads(sidecar.read_text(encoding='utf-8'))
        query = urllib.parse.urlencode({'type': 'tcp', 'security': 'reality', 'pbk': client['public_key'],
              'fp': 'chrome', 'sni': client['sni'], 'sid': client['short_id'], 'flow': client['flow']})
        return f'vless://{user["uuid"]}@{host}:{port}?{query}#{name}'
    if proto == 'shadowsocks':
        token = __import__('base64').urlsafe_b64encode(f'{item["method"]}:{item["password"]}'.encode()).decode().rstrip('=')
        return f'ss://{token}@{host}:{port}#{name}'
    if proto == 'socks':
        token = urllib.parse.quote(f'{user.get("username", "")}:{user.get("password", "")}', safe='')
        return f'socks5://{token}@{host}:{port}#{name}'
    password = user.get('password', '')
    sni = tls.get('server_name', '')
    if proto == 'vless':
        query = {'security': 'tls' if tls.get('enabled') else 'none', 'type': transport.get('type', 'tcp')}
        if sni: query['sni'] = sni
        if transport.get('path'): query['path'] = transport['path']
        return f'vless://{user["uuid"]}@{host}:{port}?{urllib.parse.urlencode(query)}#{name}'
    if proto == 'vmess':
        data = {'v': '2', 'ps': item.get('tag'), 'add': host, 'port': port, 'id': user['uuid'],
                'aid': '0', 'net': transport.get('type', 'tcp'), 'type': 'none',
                'host': sni, 'path': transport.get('path', ''),
                'tls': 'tls' if tls.get('enabled') else ''}
        raw = __import__('base64').urlsafe_b64encode(json.dumps(data, separators=(',', ':')).encode()).decode().rstrip('=')
        return 'vmess://' + raw
    if proto == 'trojan':
        query = {'security': 'tls', 'type': transport.get('type', 'tcp')}
        if sni: query['sni'] = sni
        if transport.get('path'): query['path'] = transport['path']
        return f'trojan://{urllib.parse.quote(password, safe="")}@{host}:{port}?{urllib.parse.urlencode(query)}#{name}'
    if proto == 'hysteria2':
        q = {'sni': sni, 'obfs': item.get('obfs', {}).get('type', ''),
             'obfs-password': item.get('obfs', {}).get('password', '')}
        return f'hysteria2://{urllib.parse.quote(password, safe="")}@{host}:{port}/?{urllib.parse.urlencode(q)}#{name}'
    if proto == 'tuic':
        q = {'congestion_control': item.get('congestion_control', 'cubic'), 'udp_relay_mode': 'native', 'sni': sni}
        return f'tuic://{user["uuid"]}:{urllib.parse.quote(password, safe="")}@{host}:{port}?{urllib.parse.urlencode(q)}#{name}'
    if proto == 'anytls':
        return f'anytls://{urllib.parse.quote(password, safe="")}@{host}:{port}?{urllib.parse.urlencode({"sni": sni})}#{name}'
    fail(f'{proto} 的分享链接格式暂不支持。')


def share_cmd(args) -> str:
    data = read_config()
    item = find_inbound(data, args.name)
    host = args.server
    if not host: fail('请提供 --server 公网 IP 或域名。')
    uri = share_uri(item, host)
    print(uri)
    return uri


def bbr_cmd(args) -> None:
    if not sys.platform.startswith('linux'): fail('BBR 仅支持 Linux。')
    if not args.apply:
        print('预览：将写入 net.core.default_qdisc=fq 与 net.ipv4.tcp_congestion_control=bbr。')
        print('应用请执行：sudo sb bbr --apply；这会持久修改内核参数。')
        return
    require_root()
    if not pathlib.Path('/proc/sys/net/ipv4/tcp_available_congestion_control').exists(): fail('无法读取内核拥塞控制选项。')
    available = pathlib.Path('/proc/sys/net/ipv4/tcp_available_congestion_control').read_text().split()
    if 'bbr' not in available: fail('当前内核未提供 BBR。')
    conf = pathlib.Path('/etc/sysctl.d/99-sing-box-bbr.conf')
    if conf.exists():
        backup = conf.with_name(f'{conf.name}.backup-{dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")}')
        shutil.copy2(conf, backup)
        os.chmod(backup, 0o600)
    conf.write_text('net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n', encoding='ascii')
    os.chmod(conf, 0o644)
    run(['sysctl', '--system'])
    print('BBR 已启用。')


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog='sb', description='sing-box 安装后的安全管理命令')
    sub = p.add_subparsers(dest='cmd', required=True)
    sub.add_parser('status', help='显示服务状态')
    add = sub.add_parser('add', help='添加协议入站')
    add.add_argument('protocol', choices=['reality','r','vless-reality','ss','shadowsocks','socks','socks5','vmess','tcp','ws','wss','h2','hu','http','quic','vless','vws','vh2','vhu','trojan','tws','th2','thu','anytls','tuic','hysteria2','hy','hy2','vmess-ws','vless-ws','trojan-ws','vmess-http','vless-http','trojan-http','vmess-quic','vless-quic','vmess-httpupgrade','vless-httpupgrade','trojan-httpupgrade'])
    add.add_argument('--port', type=int)
    add.add_argument('--server', help='用于输出客户端参数的服务器地址')
    add.add_argument('--sni', help='Reality SNI；Reality 默认 www.cloudflare.com')
    add.add_argument('--domain', help='TLS 域名，仅作为说明字段')
    add.add_argument('--cert', help='TLS 证书 PEM 绝对路径')
    add.add_argument('--key', help='TLS 私钥 PEM 绝对路径')
    add.add_argument('--path', help='WebSocket 路径')
    add.add_argument('--username')
    add.add_argument('--password')
    add.add_argument('--uuid')
    add.add_argument('--method', choices=['2022-blake3-aes-128-gcm','2022-blake3-aes-256-gcm','2022-blake3-chacha20-poly1305','aes-128-gcm','aes-256-gcm','chacha20-ietf-poly1305'])
    add.add_argument('--acme', action='store_true', help='使用 sb acme issue 管理的证书')
    add.add_argument('--dry-run', action='store_true', help='只生成 JSON，不写入配置')
    info = sub.add_parser('info', help='查看入站摘要；不显示密钥')
    info.add_argument('name', nargs='?')
    change = sub.add_parser('change', help='安全修改入站参数')
    change.add_argument('name'); change.add_argument('--port', type=int); change.add_argument('--uuid'); change.add_argument('--password'); change.add_argument('--sni', '--host', '--web', dest='sni'); change.add_argument('--path'); change.add_argument('--method', choices=['2022-blake3-aes-128-gcm','2022-blake3-aes-256-gcm','2022-blake3-chacha20-poly1305','aes-128-gcm','aes-256-gcm','chacha20-ietf-poly1305']); change.add_argument('--rotate-key', action='store_true')
    delete = sub.add_parser('del', help='删除入站')
    delete.add_argument('name'); delete.add_argument('--yes', action='store_true')
    share = sub.add_parser('url', help='生成支持协议的客户端分享链接')
    share.add_argument('name'); share.add_argument('--server')
    qr = sub.add_parser('qr', help='生成二维码；需要本机安装 qrencode')
    qr.add_argument('name'); qr.add_argument('--server')
    gen = sub.add_parser('gen', help='只生成配置草案')
    gen.add_argument('protocol', choices=['reality','r','vless-reality','ss','shadowsocks','socks','socks5','vmess','tcp','ws','wss','h2','hu','http','quic','vless','vws','vh2','vhu','trojan','tws','th2','thu','anytls','tuic','hysteria2','hy','hy2','vmess-ws','vless-ws','trojan-ws','vmess-http','vless-http','trojan-http','vmess-quic','vless-quic','vmess-httpupgrade','vless-httpupgrade','trojan-httpupgrade'])
    gen.add_argument('--port', type=int); gen.add_argument('--sni'); gen.add_argument('--domain'); gen.add_argument('--cert'); gen.add_argument('--key'); gen.add_argument('--path'); gen.add_argument('--username'); gen.add_argument('--password'); gen.add_argument('--uuid'); gen.add_argument('--method', choices=['2022-blake3-aes-128-gcm','2022-blake3-aes-256-gcm','2022-blake3-chacha20-poly1305','aes-128-gcm','aes-256-gcm','chacha20-ietf-poly1305'])
    gen.add_argument('--acme', action='store_true')
    bbr = sub.add_parser('bbr', help='预览/启用 BBR')
    bbr.add_argument('--apply', action='store_true')
    imp = sub.add_parser('import', help='导入 sing-box 或转换常见 Xray/V2Ray inbounds')
    imp.add_argument('file'); imp.add_argument('--yes', action='store_true')
    acme = sub.add_parser('acme', help='签发、续期或查看 ACME 证书')
    acme_sub = acme.add_subparsers(dest='acme_action', required=True)
    issue = acme_sub.add_parser('issue', help='通过 HTTP-01 签发并配置自动续期')
    issue.add_argument('--domain', required=True); issue.add_argument('--email', required=True); issue.add_argument('--webroot', help='现有 Web 服务的 challenge 根目录；省略则使用 standalone 占用 80 端口')
    acme_sub.add_parser('renew', help='立即运行续期检查')
    acme_sub.add_parser('status', help='查看证书和续期定时器')
    sub.add_parser('edit', help='用本机编辑器修改完整 JSON；校验后安全应用')
    binp = sub.add_parser('bin', help='直通 sing-box 核心命令')
    binp.add_argument('args', nargs=argparse.REMAINDER)
    return p


def main() -> None:
    if len(sys.argv) == 1:
        print('1) 查看配置  2) 服务状态  3) 添加配置  4) 退出')
        choice = input('选择：').strip()
        if choice == '1': sys.argv.append('info')
        elif choice == '2': sys.argv.append('status')
        elif choice == '4' or not choice: return
        else: fail('交互菜单仅支持查看和状态；使用 sb add --help 添加协议。', 0)
    args = build_parser().parse_args()
    if args.cmd == 'status': run(['systemctl', '--no-pager', '--full', 'status', 'sing-box.service'], check=False)
    elif args.cmd == 'add': add_cmd(args)
    elif args.cmd == 'gen':
        data = read_config(); item = make_inbound(args, data); print(json.dumps(clean_internal(item), ensure_ascii=False, indent=2))
    elif args.cmd == 'info': info_cmd(args)
    elif args.cmd == 'change': change_cmd(args)
    elif args.cmd == 'del': del_cmd(args)
    elif args.cmd == 'url': share_cmd(args)
    elif args.cmd == 'qr':
        uri = share_cmd(args)
        if not shutil.which('qrencode'): fail('未找到 qrencode；请在系统包管理器中安装后重试。')
        run(['qrencode', '-t', 'ANSIUTF8', uri])
    elif args.cmd == 'bbr': bbr_cmd(args)
    elif args.cmd == 'import': import_cmd(args)
    elif args.cmd == 'acme': acme_cmd(args)
    elif args.cmd == 'edit': edit_cmd(args)
    elif args.cmd == 'bin': run([BIN, *args.args])


if __name__ == '__main__':
    main()
SB_MANAGER_EOF
  chown root:root /usr/local/libexec/sing-box-manager.py
  chmod 0755 /usr/local/libexec/sing-box-manager.py
  cat > /usr/local/bin/sb <<'SB_WRAPPER_EOF'
#!/usr/bin/env bash
exec /usr/bin/python3 /usr/local/libexec/sing-box-manager.py "$@"
SB_WRAPPER_EOF
  chown root:root /usr/local/bin/sb
  chmod 0755 /usr/local/bin/sb
}
ensure_dependencies
ensure_identity
install -d -o root -g "$GROUP_NAME" -m 0750 "$CONFIG_DIR"
fetch_release
write_initial_config
write_service
install_manager
systemctl enable sing-box.service >/dev/null
if ! systemctl restart sing-box.service; then
  systemctl --no-pager --full status sing-box.service || true
  if [[ -n "$PREVIOUS_BIN_BACKUP" && -f "$PREVIOUS_BIN_BACKUP" ]]; then
    install -o root -g root -m 0755 -- "$PREVIOUS_BIN_BACKUP" "$BIN"
    rm -f -- "$PREVIOUS_BIN_BACKUP"
    systemctl restart sing-box.service || true
    die '更新后服务启动失败；已回滚到原程序。请检查配置和日志。'
  fi
  die '服务启动失败。配置保留以便排查；请检查日志：journalctl -u sing-box -e'
fi
systemctl is-active --quiet sing-box.service || die '服务未进入 active 状态。'
if [[ -n "$PREVIOUS_BIN_BACKUP" ]]; then rm -f -- "$PREVIOUS_BIN_BACKUP"; fi
log '安装并启动成功。'
log '状态：systemctl status sing-box'
log '日志：journalctl -u sing-box -f'
log "连接参数：sudo cat $CLIENT_INFO"
log "防火墙需按 $CONFIG 中的监听端口由你按需放行；脚本没有改动防火墙。"
