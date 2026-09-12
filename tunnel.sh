#!/usr/bin/env bash
# 使用用户级 launchd 管理隧道；仅 start 创建本工具的任务文件。
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

usage() {
  cat <<'EOF'
用法：./codex-network start|repair|stop [配置名|all] [--dry-run]

start：检查代理与 SSH，安装并启动用户级隧道。
repair：重新加载或重启已安装的任务，并验证网络。
stop：停止任务并禁用登录启动，保留配置与日志。
--dry-run：只显示目标与计划，不连接服务器或修改 launchd。
EOF
}

# SSH 会把远端命令重新交给 shell，须对每个远端参数单独转义。
quote_remote() { printf "'%s'" "${1//\'/\'\\\'\'}"; }

remote_probe() {
  local command_line
  command_line="bash -s -- $(quote_remote "$REMOTE_PORT") $(quote_remote "$REMOTE_PROXY_URL") $(quote_remote "$PROBE_URL")"
  # 参数在本机有意展开，并已逐个进行远端 shell 转义。
  # shellcheck disable=SC2029
  ssh "${SSH_OPTIONS[@]}" "$MAIN_HOST" "$command_line" < "$SCRIPT_DIR/remote-check.sh"
}

write_plist() {
  local arg
  cat <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<!-- Managed by codex-network -->
<plist version="1.0"><dict>
EOF
  printf '<key>Label</key><string>%s</string>\n' "$(xml_escape "$LAUNCH_LABEL")"
  printf '<key>ProgramArguments</key><array>\n<string>%s</string>\n' "$(xml_escape "$(command -v ssh)")"
  for arg in "${TUNNEL_ARGS[@]}"; do printf '<string>%s</string>\n' "$(xml_escape "$arg")"; done
  printf '</array>\n<key>EnvironmentVariables</key><dict>\n'
  printf '<key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>\n'
  # 继承 launchd 当前登录会话的 agent，避免把临时 socket 固化到下次登录。
  printf '</dict>\n'
  printf '<key>StandardErrorPath</key><string>%s</string>\n' "$(xml_escape "$LOG_DIR/$LAUNCH_LABEL.log")"
  printf '<key>StandardOutPath</key><string>%s</string>\n' "$(xml_escape "$LOG_DIR/$LAUNCH_LABEL.log")"
  printf '<key>RunAtLoad</key><true/><key>KeepAlive</key><true/>\n'
  printf '<key>ThrottleInterval</key><integer>10</integer><key>Umask</key><integer>63</integer>\n'
  printf '</dict></plist>\n'
}

verify_tunnel() {
  local attempt output code
  for attempt in 1 2 3; do
    printf '  [检查] 等待远端代理响应（%s/3）…\n' "$attempt"
    if output=$(remote_probe 2>/dev/null) &&
      printf '%s\n' "$output" | grep -qx 'REMOTE_PROTOCOL=1' &&
      printf '%s\n' "$output" | grep -qx 'REMOTE_CONNECTED=1' &&
      printf '%s\n' "$output" | grep -qx 'REMOTE_LISTENER=present' &&
      printf '%s\n' "$output" | grep -qx 'PROBE_CURL_EXIT=0' &&
      printf '%s\n' "$output" | grep -qx 'PROBE_STATUS=reachable'; then
      code=$(printf '%s\n' "$output" | awk -F= '$1 == "PROBE_HTTP" {print $2; exit}')
      http_code_is_reachable "$code" || continue
      printf '  [通过] 远端代理可达（HTTP %s；不代表登录或模型服务正常）。\n' "$code"
      printf '  下一步：./codex-network doctor %s\n' "$TARGET_NAME"
      return 0
    fi
    [ "$attempt" = 3 ] || sleep 2
  done
  error "隧道已启动，但远端链路未通过验证。运行 ./codex-network doctor ${TARGET_NAME}；检查 $LOG_DIR/$LAUNCH_LABEL.log"
  return 1
}

operate_target() {
  local name="$1" service plist code loaded=no temporary
  resolve_target "$name" || return 2
  if [ "$MANAGE_TUNNEL" = no ]; then
    printf '[%s] 仅诊断配置，跳过隧道管理；用 ./codex-network doctor %s 检查。\n' "$name" "$name"
    return 0
  fi
  service="gui/$(id -u)/$LAUNCH_LABEL"
  plist=$(launch_service_path)
  printf '\n[%s] %s：%s\n' "$name" "$operation" "$TUNNEL_HOST"
  if [ "$operation" = start ] && [ "$LAUNCH_LABEL" != "io.github.codex-network.$TARGET_NAME" ]; then
    error "现有外部任务请使用 ./codex-network repair ${name}；start 仅安装 io.github.codex-network.${name}。"; return 1
  fi
  if [ "$dry_run" = yes ]; then
    printf '  远端 127.0.0.1:%s → 本机 127.0.0.1:%s\n  任务：%s\n  文件：%s\n' "$REMOTE_PORT" "$LOCAL_PROXY_PORT" "$service" "$plist"
    case "$operation" in
      start) printf '  计划：检查代理及 SSH，生成任务文件，enable / bootstrap，验证远端。\n' ;;
      restart) printf '  计划：检查代理及 SSH，enable，bootstrap 或 kickstart -k，验证远端。\n' ;;
      stop) printf '  计划：bootout（若运行中），disable；保留任务文件及日志。\n' ;;
    esac
    return 0
  fi

  launchctl print "$service" >/dev/null 2>&1 && loaded=yes
  if [ "$operation" = stop ]; then
    if [ "$loaded" = yes ]; then launchctl bootout "$service" || return 1; fi
    launchctl disable "$service" || return 1
    printf '  [完成] 已停止并禁用登录启动。重新启用：./codex-network start %s\n' "$name"
    return 0
  fi

  code=$(check_local_proxy) || true
  http_code_is_reachable "${code:-000}" || {
    error "本机 127.0.0.1:$LOCAL_PROXY_PORT 代理不可达（HTTP ${code:-000}），请先启动代理。"; return 1;
  }
  prepare_tunnel || return 1
  if ! ssh "${SSH_OPTIONS[@]}" "$TUNNEL_HOST" true; then
    error "SSH 预检失败；请先运行 ssh ${TUNNEL_HOST}，确认主机指纹与免交互密钥认证。"; return 1
  fi

  if [ "$operation" = start ]; then
    if [ -e "$plist" ] && ! grep -Fq '<!-- Managed by codex-network -->' "$plist"; then
      error "任务文件不属于本工具，拒绝覆盖：$plist"; return 1
    fi
    umask 077
    mkdir -p "$LAUNCH_DIR" "$LOG_DIR" || return 1
    temporary=$(mktemp "$LAUNCH_DIR/.codex-network.XXXXXX") || return 1
    if ! write_plist > "$temporary" || ! plutil -lint -- "$temporary" >/dev/null; then
      rm -f "$temporary"
      error '生成 launchd 任务失败。'; return 1
    fi
    if [ "$loaded" = yes ]; then
      if ! cmp -s "$temporary" "$plist"; then
        rm -f "$temporary"
        error "运行中的任务与当前配置不同；先 ./codex-network stop ${name}，再 start ${name}。"; return 1
      fi
      rm -f "$temporary"
    else
      mv "$temporary" "$plist" || return 1
    fi
  else
    [ -f "$plist" ] || { error "尚未安装任务，请先 ./codex-network start ${name}。"; return 1; }
    # 自有任务的启动参数变化须通过 stop/start 更新，不能重启旧端口后报告成功。
    if grep -Fq '<!-- Managed by codex-network -->' "$plist" && ! cmp -s "$plist" <(write_plist); then
      error "配置与已安装任务不同；先 ./codex-network stop ${name}，再 start ${name}。"; return 1
    fi
  fi

  launchctl enable "$service" || return 1
  if [ "$loaded" = no ]; then
    launchctl bootstrap "gui/$(id -u)" "$plist" || { error "无法加载任务：$plist"; return 1; }
  elif [ "$operation" = start ]; then
    # 重复 start 不打断正在工作的连接；只有 repair 强制重启。
    launchctl kickstart "$service" || return 1
  else
    launchctl kickstart -k "$service" || return 1
  fi
  printf '  [完成] 隧道已启动，断线时自动重连。\n'
  verify_tunnel
}

operation="${1:-help}"
[ "$#" -eq 0 ] || shift
case "$operation" in
  -h|--help|help) usage; exit 0 ;;
  start|stop|restart) ;;
  *) usage >&2; exit 2 ;;
esac
selector=all selected=no dry_run=no
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --dry-run) dry_run=yes ;;
    -*) usage >&2; exit 2 ;;
    *) [ "$selected" = no ] || { usage >&2; exit 2; }; selector="$1"; selected=yes ;;
  esac
  shift
done
select_targets "$selector" || exit 2
if [ "$dry_run" = no ]; then
  [ "$(uname -s)" = Darwin ] || { error 'start/repair/stop 需要 macOS 的用户级 launchd；可用 doctor 诊断。'; exit 1; }
  require_commands launchctl ssh curl plutil || exit 1
fi
failures=0
for target in "${targets[@]}"; do operate_target "$target" || failures=$((failures + 1)); done
[ "$failures" -eq 0 ]
