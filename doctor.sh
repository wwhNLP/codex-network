#!/usr/bin/env bash
# 只读诊断本机代理、SSH 隧道和远端应用的代理配置。

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

FAILURES=0
WARNINGS=0

pass() { printf '  [通过] %s\n' "$*"; }
fail() { printf '  [失败] %s\n' "$*"; FAILURES=$((FAILURES + 1)); }
warn() { printf '  [警告] %s\n' "$*"; WARNINGS=$((WARNINGS + 1)); }
info() { printf '  [信息] %s\n' "$*"; }

usage() {
  cat <<'EOF'
用法：./codex-network doctor [目标名|all]

默认检查全部已配置的目标；只读取状态，不修改本机或远端配置。
首次使用请运行 ./codex-network init，随后运行 ./codex-network start 目标名。

返回码：0 = 未发现故障（可能有警告），1 = 发现故障，2 = 参数或配置错误。
EOF
}

collect_remote_status() {
  local port_arg proxy_arg probe_arg
  # SSH 会重新拼接远端命令，必须保护 URL 中的 shell 特殊字符。
  port_arg=$(printf '%s' "$REMOTE_PORT" | sed "s/'/'\\\\''/g")
  proxy_arg=$(printf '%s' "$REMOTE_PROXY_URL" | sed "s/'/'\\\\''/g")
  probe_arg=$(printf '%s' "$PROBE_URL" | sed "s/'/'\\\\''/g")
  # 参数在本机有意展开，并已逐个进行远端 shell 转义。
  # shellcheck disable=SC2029
  ssh "${SSH_OPTIONS[@]}" "$MAIN_HOST" \
    "bash -s -- '$port_arg' '$proxy_arg' '$probe_arg'" < "$SCRIPT_DIR/remote-check.sh"
}

remote_value() {
  printf '%s\n' "$remote_output" | awk -F= -v key="$1" '$1 == key {print $2; exit}'
}

check_target() {
  local local_code forward_result launch_state remote_output remote_exit
  local listener settings_state probe_code probe_exit probe_state codex_state
  local process_count correct_count stale_count unknown_count
  resolve_target "$1" || { fail "无法读取目标配置：$1"; return; }
  printf '\n[%s] SSH=%s，远端代理=%s\n' "$TARGET_NAME" "$MAIN_HOST" "$REMOTE_PROXY_URL"

  local_code=$(check_local_proxy)
  if http_code_is_reachable "${local_code:-000}"; then
    pass "本机代理 127.0.0.1:$LOCAL_PROXY_PORT 可访问探针（HTTP ${local_code}）"
  else
    fail "本机代理 127.0.0.1:$LOCAL_PROXY_PORT 不可用（HTTP ${local_code:-000}）；请检查代理客户端和端口"
  fi

  if [ "$MANAGE_TUNNEL" = no ]; then
    info "手动隧道以远端监听和实际探针为准；请确保只绑定 127.0.0.1"
  elif forward_result=$(prepare_tunnel 2>&1); then
    pass "SSH 转发配置可用于目标隧道"
  else
    fail "SSH 转发配置不符合要求：$forward_result"
  fi

  if [ "$MANAGE_TUNNEL" = yes ]; then
    if command -v launchctl >/dev/null 2>&1; then
      launch_state=$(launchctl print "gui/$(id -u)/$LAUNCH_LABEL" 2>/dev/null | awk '/^[[:space:]]*state =/{print $3; exit}')
      if [ "$launch_state" = running ]; then
        pass "launchd 隧道正在运行（${LAUNCH_LABEL}）"
      else
        fail "launchd 隧道未运行（${launch_state:-未加载}）；可运行 ./codex-network repair $TARGET_NAME"
      fi
    else
      warn "本机没有 launchctl，无法检查 macOS 托管隧道；可使用手动 SSH 隧道"
    fi
  else
    info "该目标由用户自行管理 SSH 隧道（MANAGE_TUNNEL=no）"
  fi

  remote_exit=0
  remote_output=$(collect_remote_status 2>&1) || remote_exit=$?
  if [ "$remote_exit" -ne 0 ] || [ "$(remote_value REMOTE_PROTOCOL)" != 1 ] || [ "$(remote_value REMOTE_CONNECTED)" != 1 ]; then
    fail "SSH 检查未完成（退出码 ${remote_exit}）；请先运行 ssh $MAIN_HOST 验证登录、主机密钥和远端 Bash"
    # 不回显任意远端输出，以免认证插件或登录脚本打印敏感信息。
    return
  fi
  pass "SSH 远端检查已完成"

  listener=$(remote_value REMOTE_LISTENER)
  case "$listener" in
    present) pass "远端 127.0.0.1:$REMOTE_PORT 正在监听" ;;
    missing) fail "未发现远端 127.0.0.1:$REMOTE_PORT 监听；请检查隧道是否建立" ;;
    *) warn "远端缺少可用的 ss/netstat，无法确认监听状态" ;;
  esac

  settings_state=$(remote_value VSCODE_PROXY)
  case "$settings_state" in
    correct) pass "VS Code 远端 http.proxy 与目标代理一致" ;;
    mismatch) warn "VS Code 远端 http.proxy 不匹配；请参考 README 的远端配置步骤" ;;
    missing) warn "未找到 VS Code 远端 http.proxy；使用 VS Code 时请按 README 配置，不使用时可忽略" ;;
    *) warn "无法解析 VS Code 远端设置（可能缺少 python3、文件不可读或 JSONC 格式错误）" ;;
  esac

  probe_code=$(remote_value PROBE_HTTP)
  probe_exit=$(remote_value PROBE_CURL_EXIT)
  probe_state=$(remote_value PROBE_STATUS)
  if [ "$probe_state" = reachable ] && [ "$probe_exit" = 0 ] && http_code_is_reachable "${probe_code:-000}"; then
    pass "远端通过代理访问探针成功（HTTP ${probe_code}）"
    case "$probe_code" in
      401|403) info "HTTP $probe_code 仅证明链路可达，不代表登录、权限或 Codex 业务正常" ;;
    esac
  elif [ "$probe_state" = unknown ]; then
    warn "远端没有 curl，无法执行端到端代理探针"
  else
    fail "远端代理探针失败（curl ${probe_exit:-未知}，HTTP ${probe_code:-000}）"
  fi

  codex_state=$(remote_value CODEX_STATE)
  process_count=$(remote_value CODEX_TOTAL)
  correct_count=$(remote_value CODEX_CORRECT)
  stale_count=$(remote_value CODEX_STALE)
  unknown_count=$(remote_value CODEX_UNKNOWN)
  info "同用户 Codex app-server：${process_count:-0} 个；代理匹配 ${correct_count:-0}，不匹配 ${stale_count:-0}，未知 ${unknown_count:-0}"
  case "$codex_state" in
    correct) pass "所有可见 app-server 的代理环境符合配置" ;;
    stale) warn "app-server 代理环境不匹配；更新启动环境后重启对应远端 Codex 会话（VS Code 可执行 Developer: Reload Window）" ;;
    mixed) warn "多个 app-server 的代理状态不一致；请按对应会话分别检查并重启" ;;
    none) info "当前未发现 app-server；尚未打开远端 Codex 会话时属于正常情况" ;;
    *) warn "无法完整判断 app-server 代理环境（权限限制、变量冲突或 NO_PROXY 可能绕过代理）" ;;
  esac
}

if [ "$#" -gt 1 ]; then usage >&2; exit 2; fi
case "${1:-all}" in
  -h|--help) usage; exit 0 ;;
  -*) usage >&2; exit 2 ;;
esac
select_targets "${1:-all}" || exit 2
require_commands ssh curl awk sed || exit 2

for target in "${targets[@]}"; do
  check_target "$target"
done

printf '\n诊断完成：%d 个失败，%d 个警告。\n' "$FAILURES" "$WARNINGS"
info "本检查验证网络和代理配置；成功不代表账号权限或所有 Codex 功能正常。"
[ "$FAILURES" -eq 0 ]
