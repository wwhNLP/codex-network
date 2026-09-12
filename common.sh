#!/usr/bin/env bash
# 配置是数据，不使用 source 或 eval 执行用户填写的内容。
# 此文件由入口脚本加载，以下公共变量由调用方读取。
# shellcheck disable=SC2034

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${CODEX_NETWORK_CONFIG_DIR:-$SCRIPT_DIR/config}"
LAUNCH_DIR="${CODEX_NETWORK_LAUNCH_DIR:-$HOME/Library/LaunchAgents}"
LOG_DIR="${CODEX_NETWORK_LOG_DIR:-$HOME/Library/Logs/codex-network}"
SSH_OPTIONS=(-T -o BatchMode=yes -o ConnectTimeout=8 -o ConnectionAttempts=1
  -o ForkAfterAuthentication=no -o RemoteCommand=none
  -o ClearAllForwardings=yes -o ControlMaster=no -o ControlPath=none
  -o ServerAliveInterval=10 -o ServerAliveCountMax=2)

error() { printf '[失败] %s\n' "$*" >&2; }

require_commands() {
  local tool
  for tool in "$@"; do
    command -v "$tool" >/dev/null 2>&1 || { error "缺少命令：$tool"; return 1; }
  done
}

valid_name() {
  [[ "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]] && [ "${#1}" -le 48 ] &&
    [ "$1" != all ] && [ "$1" != example ]
}

valid_port() {
  [[ "$1" =~ ^[1-9][0-9]{0,4}$ ]] && [ "$1" -le 65535 ]
}

valid_host() {
  [[ "$1" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.@-]*$ ]]
}

resolve_target() {
  local name="$1" file line key value seen='|' line_number=0
  valid_name "$name" || { error "配置名只能使用字母、数字、下划线和连字符，且不能为 all/example。"; return 2; }
  file="$CONFIG_DIR/$name.conf"
  [ -f "$file" ] || { error "找不到配置 ${file}；先运行 ./codex-network init ${name}。"; return 2; }
  TARGET_NAME="$name"
  SSH_HOST='' TUNNEL_HOST='' LOCAL_PROXY_PORT=7897 REMOTE_PORT=17897
  PROBE_URL='https://chatgpt.com/' MANAGE_TUNNEL=yes
  LAUNCH_LABEL="io.github.codex-network.$name"
  while IFS= read -r line || [ -n "$line" ]; do
    line_number=$((line_number + 1))
    line="${line%$'\r'}"
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    if [[ ! "$line" =~ ^([A-Z_]+)=(.*)$ ]]; then
      error "$file:$line_number 必须使用 KEY=VALUE，不加引号或空格。"; return 2
    fi
    key="${BASH_REMATCH[1]}" value="${BASH_REMATCH[2]}"
    case "$key" in
      SSH_HOST|TUNNEL_HOST|LOCAL_PROXY_PORT|REMOTE_PORT|PROBE_URL|MANAGE_TUNNEL|LAUNCH_LABEL) ;;
      *) error "$file:$line_number 未知配置项 $key"; return 2 ;;
    esac
    case "$seen" in *"|$key|"*) error "$file:$line_number 重复配置项 $key"; return 2 ;; esac
    seen="$seen$key|"
    printf -v "$key" '%s' "$value"
  done < "$file"
  MAIN_HOST="$SSH_HOST"
  TUNNEL_HOST="${TUNNEL_HOST:-$MAIN_HOST}"
  if ! valid_host "$MAIN_HOST" || ! valid_host "$TUNNEL_HOST"; then
    error "${file}：请填写有效的 SSH 别名或 user@host。"; return 2
  fi
  if ! valid_port "$LOCAL_PROXY_PORT" || ! valid_port "$REMOTE_PORT"; then
    error "${file}：端口必须为 1–65535 的十进制数字。"; return 2
  fi
  case "$MANAGE_TUNNEL" in yes|no) ;; *) error "${file}：MANAGE_TUNNEL 只能为 yes/no。"; return 2 ;; esac
  [[ "$LAUNCH_LABEL" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || { error "${file}：launchd label 无效。"; return 2; }
  if [[ ! "$PROBE_URL" =~ ^https://[^/[:space:]@]+(/[^[:space:]]*)?$ ]]; then
    error "${file}：PROBE_URL 必须是无凭据、无空白的 HTTPS 地址。"; return 2
  fi
  REMOTE_PROXY_URL="http://127.0.0.1:$REMOTE_PORT"
}

list_targets() {
  local file name
  for file in "$CONFIG_DIR"/*.conf; do
    [ -f "$file" ] || continue
    name="${file##*/}"; name="${name%.conf}"
    valid_name "$name" && printf '%s\n' "$name"
  done
  return 0
}

select_targets() {
  local selector="${1:-all}" name
  targets=()
  if [ "$selector" = all ]; then
    while IFS= read -r name; do targets+=("$name"); done < <(list_targets)
  else
    targets=("$selector")
  fi
  [ "${#targets[@]}" -gt 0 ] || { error "尚未配置服务器。运行 ./codex-network init 开始。"; return 2; }
  # 先验证整批配置，避免执行到一半才发现参数错误。
  for name in "${targets[@]}"; do resolve_target "$name" || return 2; done
}

http_code_is_reachable() {
  # 这是传输连通性，不代表登录、地区授权或模型服务正常。
  case "$1" in 2??|3??|401|403) return 0 ;; *) return 1 ;; esac
}

check_local_proxy() {
  local code
  if code=$(curl -q --noproxy '' -x "http://127.0.0.1:$LOCAL_PROXY_PORT" \
    -o /dev/null -sS -w '%{http_code}' --connect-timeout 5 --max-time 12 \
    "$PROBE_URL" 2>/dev/null); then
    printf '%s\n' "$code"
  else
    printf '000\n'
    return 1
  fi
}

prepare_tunnel() {
  local effective forwards expected
  TUNNEL_ARGS=(-N -T -o BatchMode=yes -o ConnectTimeout=8 -o ConnectionAttempts=1
    -o ForkAfterAuthentication=no -o RemoteCommand=none
    -o ClearAllForwardings=no -o ControlMaster=no -o ControlPath=none
    -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3)
  effective=$(ssh -G "${TUNNEL_ARGS[@]}" "$TUNNEL_HOST" 2>/dev/null) || {
    error "无法解析 SSH 配置：$TUNNEL_HOST"; return 1;
  }
  if printf '%s\n' "$effective" | grep -Eq '^(localforward|dynamicforward) '; then
    error "$TUNNEL_HOST 包含其他本地转发，请使用 examples/ssh-config 中的专用别名。"; return 1
  fi
  forwards=$(printf '%s\n' "$effective" | awk '$1 == "remoteforward" { gsub(/[][]/, ""); print $2, $3 }')
  expected="127.0.0.1:$REMOTE_PORT 127.0.0.1:$LOCAL_PROXY_PORT"
  if [ -z "$forwards" ]; then
    TUNNEL_ARGS+=(-R "127.0.0.1:$REMOTE_PORT:127.0.0.1:$LOCAL_PROXY_PORT")
  elif [ "$forwards" != "$expected" ]; then
    error "$TUNNEL_HOST 的 RemoteForward 不匹配或不止一条；预期 ${expected}。"; return 1
  fi
  TUNNEL_ARGS+=("$TUNNEL_HOST")
}

launch_service_path() { printf '%s/%s.plist' "$LAUNCH_DIR" "$LAUNCH_LABEL"; }

xml_escape() {
  # sed 的替换规则在 Bash 3.2 和新版 Bash 中一致。
  printf '%s' "$1" | sed -e 's/\&/\&amp;/g' -e 's/</\&lt;/g' \
    -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' -e "s/'/\&apos;/g"
}
