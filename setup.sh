#!/usr/bin/env bash
# 初始化只创建本地配置；通过 start 显式启动隧道。
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

usage() {
  cat <<'EOF'
用法：./codex-network init [配置名] [--host SSH别名] [--local-port 7897] [--remote-port 17897]

配置名默认为 default。交互模式会询问 SSH 别名和端口。
非交互模式请提供 --host。已有配置不会被覆盖。
EOF
}

name=default host='' local_port='' remote_port='' named=no
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --host|--local-port|--remote-port)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      case "$1" in
        --host) host="$2" ;;
        --local-port) local_port="$2" ;;
        --remote-port) remote_port="$2" ;;
      esac
      shift 2 ;;
    -*) error "未知选项：$1"; usage >&2; exit 2 ;;
    *)
      [ "$named" = no ] || { usage >&2; exit 2; }
      name="$1"; named=yes; shift ;;
  esac
done
valid_name "$name" || { error '配置名无效；使用字母、数字、下划线或连字符，不使用 all/example。'; exit 2; }
file="$CONFIG_DIR/$name.conf"
[ ! -e "$file" ] && [ ! -L "$file" ] || { error "配置已存在：${file}，请编辑该文件或使用新的配置名。"; exit 2; }

if [ -z "$host" ]; then
  [ -t 0 ] || { error '非交互模式需要 --host，例如：./codex-network init dev --host my-server'; exit 2; }
  read -r -p 'SSH 别名（已能通过 ssh 连接）：' host || exit 2
  if [ -z "$local_port" ]; then read -r -p '本机 HTTP 代理端口 [7897]：' local_port || exit 2; fi
  if [ -z "$remote_port" ]; then read -r -p '远端回环代理端口 [17897]：' remote_port || exit 2; fi
fi
local_port="${local_port:-7897}"; remote_port="${remote_port:-17897}"
valid_host "$host" || { error 'SSH 别名无效，请勿填写空格、命令或 URL。'; exit 2; }
if ! valid_port "$local_port" || ! valid_port "$remote_port"; then
  error '端口必须为 1–65535 的十进制数字。'; exit 2
fi

umask 077
mkdir -p "$CONFIG_DIR" || exit 1
# noclobber 同时防止并发初始化覆盖已有文件。
if ! (set -o noclobber; printf '# 本机私有配置，不提交到 Git。\nSSH_HOST=%s\nLOCAL_PROXY_PORT=%s\nREMOTE_PORT=%s\nPROBE_URL=https://chatgpt.com/\nMANAGE_TUNNEL=yes\n' \
  "$host" "$local_port" "$remote_port" > "$file"); then
  error "无法创建配置：$file"; exit 1
fi
printf '已创建配置：%s\n\n接下来：\n  ./codex-network start %s\n  ./codex-network doctor %s\n\n在 VS Code 的远端设置 JSON 中合并：\n  "http.proxy": "http://127.0.0.1:%s"\n' "$file" "$name" "$name" "$remote_port"
