#!/usr/bin/env bash
# 保留简短修复入口，重启与验证逻辑统一由隧道管理脚本提供。

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

usage() {
  cat <<'EOF'
用法：./codex-network repair [目标名|all] [--dry-run]

重启并验证已配置的 macOS 托管隧道。
默认处理全部目标；MANAGE_TUNNEL=no 的目标不能自动修复，请手动重连。
--dry-run 仅显示计划，不加载或重启隧道。
EOF
}

case "${1:-}" in
  -h|--help)
    if [ "$#" -ne 1 ]; then usage >&2; exit 2; fi
    usage
    exit 0
    ;;
esac

exec bash "$SCRIPT_DIR/tunnel.sh" restart "$@"
