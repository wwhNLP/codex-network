#!/usr/bin/env bash
# 通过标准输入在 Linux 远端执行；仅输出状态，不回显配置或进程环境。

set -u
if [ "$#" -ne 3 ]; then
  printf '远端检查需要端口、代理 URL 和探针 URL。\n' >&2
  exit 2
fi
port=$1
proxy_url=$2
probe_url=$3
printf 'REMOTE_PROTOCOL=1\nREMOTE_CONNECTED=1\n'

listener=unknown
if command -v ss >/dev/null 2>&1 && sockets=$(ss -ltn 2>/dev/null); then
  listener=missing
  if printf '%s\n' "$sockets" | awk -v address="127.0.0.1:$port" '$4 == address {found=1} END {exit !found}'; then
    listener=present
  fi
elif command -v netstat >/dev/null 2>&1 && sockets=$(netstat -ltn 2>/dev/null); then
  listener=missing
  if printf '%s\n' "$sockets" | awk -v address="127.0.0.1:$port" '$4 == address {found=1} END {exit !found}'; then
    listener=present
  fi
fi
printf 'REMOTE_LISTENER=%s\n' "$listener"

settings="$HOME/.vscode-server/data/Machine/settings.json"
if [ ! -e "$settings" ]; then
  settings_state=missing
elif [ ! -r "$settings" ] || ! command -v python3 >/dev/null 2>&1; then
  settings_state=unknown
else
  settings_state=$(python3 - "$settings" "$proxy_url" <<'PYTHON'
import json
import sys


def strip_jsonc(text):
    # 逐字符保留字符串，避免把代理 URL 中的 // 当成注释。
    output = []
    i = 0
    quoted = False
    while i < len(text):
        char = text[i]
        if quoted:
            output.append(char)
            if char == "\\":
                i += 1
                if i < len(text):
                    output.append(text[i])
            elif char == '"':
                quoted = False
        elif char == '"':
            quoted = True
            output.append(char)
        elif text.startswith("//", i):
            end = text.find("\n", i + 2)
            i = len(text) if end < 0 else end
            output.append("\n")
            continue
        elif text.startswith("/*", i):
            end = text.find("*/", i + 2)
            if end < 0:
                raise ValueError("未闭合的注释")
            output.append(" ")
            i = end + 2
            continue
        else:
            output.append(char)
        i += 1
    text = "".join(output)
    output = []
    i = 0
    quoted = False
    while i < len(text):
        char = text[i]
        if quoted:
            output.append(char)
            if char == "\\":
                i += 1
                if i < len(text):
                    output.append(text[i])
            elif char == '"':
                quoted = False
        elif char == '"':
            quoted = True
            output.append(char)
        elif char == ",":
            end = i + 1
            while end < len(text) and text[end].isspace():
                end += 1
            if end == len(text) or text[end] not in "}]":
                output.append(char)
        else:
            output.append(char)
        i += 1
    return "".join(output)


try:
    with open(sys.argv[1], encoding="utf-8-sig") as source:
        settings = json.loads(strip_jsonc(source.read()))
    if not isinstance(settings, dict):
        raise ValueError("设置必须是对象")
    if "http.proxy" not in settings:
        print("missing")
    else:
        print("correct" if settings["http.proxy"] == sys.argv[2] else "mismatch")
except (OSError, ValueError, UnicodeError):
    print("unknown")
PYTHON
  ) || settings_state=unknown
fi
printf 'VSCODE_PROXY=%s\n' "$settings_state"

probe_code=000
probe_exit=127
probe_state=unknown
if command -v curl >/dev/null 2>&1; then
  probe_exit=0
  # -q 禁用用户 curlrc；--noproxy '' 保证探针确实经过指定代理。
  probe_code=$(curl -q --proxy "$proxy_url" --noproxy '' \
    --output /dev/null --silent --show-error --write-out '%{http_code}' \
    --connect-timeout 8 --max-time 20 "$probe_url" 2>/dev/null) || probe_exit=$?
  case "$probe_code" in
    [0-9][0-9][0-9]) ;;
    *) probe_code=000 ;;
  esac
  probe_state=failed
  if [ "$probe_exit" -eq 0 ]; then
    case "$probe_code" in 2??|3??|401|403) probe_state=reachable ;; esac
  fi
fi
printf 'PROBE_HTTP=%s\nPROBE_CURL_EXIT=%s\nPROBE_STATUS=%s\n' "$probe_code" "$probe_exit" "$probe_state"

is_app_server() {
  local executable argument skip_value
  IFS= read -r -d '' executable || return 1
  case "${executable##*/}" in
    codex|codex-x86_64-unknown-linux-*|codex-aarch64-unknown-linux-*) ;;
    *) return 1 ;;
  esac
  skip_value=no
  while IFS= read -r -d '' argument; do
    if [ "$skip_value" = yes ]; then skip_value=no; continue; fi
    case "$argument" in
      -c|--config|-p|--profile|-C|--cd|-m|--model|--enable|--disable) skip_value=yes ;;
      --) return 1 ;;
      -*) ;;
      app-server) return 0 ;;
      *) return 1 ;;
    esac
  done
  return 1
}

no_proxy_may_bypass() {
  local entries entry host
  entries=$1
  host=${probe_url#*://}
  host=${host%%/*}
  host=${host%%\?*}
  host=${host%%:*}
  # 统一大小写，兼容大小写不同的域名和逗号两侧空白。
  host=$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')
  entries=$(printf '%s' "$entries" | tr '[:upper:]' '[:lower:]')
  while [ -n "$entries" ]; do
    entry=${entries%%,*}
    if [ "$entries" = "$entry" ]; then entries=; else entries=${entries#*,}; fi
    entry=$(printf '%s' "$entry" | tr -d '[:space:]')
    case "$entry" in
      '') continue ;;
      '*'|*/*|*\**|*\[*) return 0 ;;
    esac
    entry=${entry%%:*}
    entry=${entry#.}
    case "$host" in "$entry"|*."$entry") return 0 ;; esac
  done
  return 1
}

classify_environment() {
  local entry https_upper https_lower all_upper all_lower bypass_upper bypass_lower effective
  https_upper='' https_lower='' all_upper='' all_lower='' bypass_upper='' bypass_lower=''
  while IFS= read -r -d '' entry; do
    case "$entry" in
      HTTPS_PROXY=*) https_upper=${entry#*=} ;;
      https_proxy=*) https_lower=${entry#*=} ;;
      ALL_PROXY=*) all_upper=${entry#*=} ;;
      all_proxy=*) all_lower=${entry#*=} ;;
      NO_PROXY=*) bypass_upper=${entry#*=} ;;
      no_proxy=*) bypass_lower=${entry#*=} ;;
    esac
  done
  if [ -n "$https_upper" ] && [ -n "$https_lower" ] && [ "$https_upper" != "$https_lower" ]; then
    printf 'unknown\n'; return
  fi
  effective=${https_lower:-$https_upper}
  if [ -z "$effective" ]; then
    if [ -n "$all_upper" ] && [ -n "$all_lower" ] && [ "$all_upper" != "$all_lower" ]; then
      printf 'unknown\n'; return
    fi
    effective=${all_lower:-$all_upper}
  fi
  if [ "$effective" != "$proxy_url" ]; then
    printf 'stale\n'
  elif no_proxy_may_bypass "$bypass_upper" || no_proxy_may_bypass "$bypass_lower"; then
    printf 'unknown\n'
  else
    printf 'correct\n'
  fi
}

process_count=0
correct_count=0
stale_count=0
unknown_count=0
codex_state=none
if [ ! -d /proc/self ]; then
  codex_state=unknown
else
  for process_dir in /proc/[0-9]*; do
    # -O 限定同一有效用户，不读取其他用户的进程环境。
    [ -O "$process_dir" ] || continue
    [ -r "$process_dir/cmdline" ] || continue
    if ! is_app_server < "$process_dir/cmdline" 2>/dev/null; then continue; fi
    process_count=$((process_count + 1))
    if [ ! -r "$process_dir/environ" ]; then
      state=unknown
    else
      state=$(classify_environment < "$process_dir/environ" 2>/dev/null) || state=unknown
    fi
    case "$state" in
      correct) correct_count=$((correct_count + 1)) ;;
      stale) stale_count=$((stale_count + 1)) ;;
      *) unknown_count=$((unknown_count + 1)) ;;
    esac
  done
  if [ "$process_count" -gt 0 ]; then
    if [ "$correct_count" -eq "$process_count" ]; then codex_state=correct
    elif [ "$stale_count" -eq "$process_count" ]; then codex_state=stale
    elif [ "$unknown_count" -eq "$process_count" ]; then codex_state=unknown
    else codex_state=mixed
    fi
  fi
fi
printf 'CODEX_STATE=%s\nCODEX_TOTAL=%s\nCODEX_CORRECT=%s\nCODEX_STALE=%s\nCODEX_UNKNOWN=%s\n' \
  "$codex_state" "$process_count" "$correct_count" "$stale_count" "$unknown_count"
