# codex-network

让远程 Linux 上的 Codex 通过 Mac 本机 HTTP 代理联网，并提供配置向导、隧道启停和逐项诊断。

适用于「Mac 本机代理 → SSH 反向转发 → 远程 Linux → VS Code 中的 Codex」场景。兼容任意提供 HTTP 代理端口的客户端。

## 快速开始

本机需要 macOS、Bash 3.2+、OpenSSH、curl 和 launchd；远端需要 Linux、Bash、curl，以及 `ss` 或 `netstat`。无需安装 pip、npm 或 Homebrew 软件包。远端可选安装 Python 3，用于准确解析含注释的 VS Code 设置 JSON；进程检查使用 Bash，不依赖 Python。

克隆仓库后，进入项目目录（下载 ZIP 的用户可直接解压进入目录）：

```bash
git clone https://github.com/wwhNLP/codex-network.git
cd codex-network

# 先手工连接，确认服务器指纹，并确保 SSH 密钥认证可用
ssh remote-dev

# 返回 Mac 终端后，创建本地配置；省略 --host 会交互询问
./codex-network init dev --host remote-dev

# 查看将执行的计划
./codex-network start dev --dry-run

# 启动隧道，同时设置为登录 Mac 后自动启动
./codex-network start dev
```

将 `remote-dev` 替换为自己的 SSH 别名，`dev` 是本工具的配置名。本机 HTTP 代理默认是 `127.0.0.1:7897`，远端代理默认是 `http://127.0.0.1:17897`。先启动自己的代理客户端，并确认其 HTTP 端口；如果不同，用下面的命令替代上面的初始化命令：

```bash
./codex-network init dev --host remote-dev --local-port 7890 --remote-port 17897
```

在 VS Code **连接该服务器后的远端设置 JSON** 中，合并下面这一项，再执行 `Developer: Reload Window`：

```json
{
  "http.proxy": "http://127.0.0.1:17897"
}
```

请保留已有设置；示例不是让你覆盖整个文件。端口应与 `REMOTE_PORT` 一致。工具只检查设置，不会自动修改远端设置文件。也可参考 [带注释的设置示例](examples/vscode-settings.jsonc)。

最后检查整条链路：

```bash
./codex-network doctor dev
```

正常时，本机代理、SSH 转发、隧道任务、远端监听和远端代理请求等检查应通过；已启动的 Codex 进程也应使用预期代理。未安装 VS Code、没有运行 Codex、缺少可选检查依赖时，请按输出提示处理。诊断通过仍不等于账号登录、模型调用或完整会话已经验证。

## 命令

| 命令 | 用途 |
| --- | --- |
| `./codex-network init [profile] [选项]` | 创建本地配置，默认名称 `default`；不连接 SSH，也不启动服务 |
| `./codex-network start [profile\|all]` | 创建并加载本用户 launchd 隧道任务，登录后自动启动、断线自动重连 |
| `./codex-network doctor [profile\|all]` | 只读诊断，不修改配置或重启服务 |
| `./codex-network repair [profile\|all]` | 重启受管理的隧道，再诊断验证 |
| `./codex-network stop [profile\|all]` | 停止隧道并禁用其自动启动，保留本地配置 |
| `./codex-network list` | 显示已有配置 |
| `./codex-network help` | 查看参数说明 |

`start`、`doctor`、`repair`、`stop` 默认处理 `all`。修改服务前可用 `--dry-run` 查看计划，例如 `./codex-network repair work --dry-run`。`init` 支持 `--host`、`--local-port`、`--remote-port`；非交互运行时必须提供 `--host`。

兼容入口仍可使用：`./setup.sh` 对应初始化，`./doctor.sh` 对应诊断，`./repair.sh` 对应修复。

## SSH 配置

先在自己的 `~/.ssh/config` 中配置 SSH 别名，可参考 [SSH 示例](examples/ssh-config)。工具不修改该文件。如果别名没有配置转发，启动时工具会添加：

```text
-R 127.0.0.1:17897:127.0.0.1:7897
```

如果已经配置 `RemoteForward`，只接受与当前端口配置一致、绑定 `127.0.0.1` 的单条转发；不同转发、额外转发或 `LocalForward` 会被拒绝。请检查包含 `Host *`、`Include` 在内的最终 SSH 配置。如果日常登录别名包含其他转发，为此工具配置专用别名，并通过 `TUNNEL_HOST` 指定它。

自动隧道使用非交互 SSH 认证。首次运行前手工 `ssh` 确认主机指纹，并准备可用的密钥认证。默认继承 launchd 当前登录会话的系统 SSH agent，使用加密私钥时需确保该 agent 可以使用密钥。远端 SSH 服务也必须允许远程端口转发。

如果使用第三方或自定义 SSH agent，请在对应 SSH 别名中用 `IdentityAgent` 指定适当的 socket 路径。仅在终端中设置 `SSH_AUTH_SOCK` 不会传递给自动启动任务；工具不会把当前终端的临时 socket 路径写入 plist。

远端代理只绑定回环地址，但多用户服务器上的其他本地用户仍可能访问这个端口。只在可信服务器上使用，避免通过该隧道暴露带有敏感权限的代理。

## 配置与多服务器

每个配置保存在 `config/<profile>.conf`，由 Git 忽略。公开示例 [config/example.conf](config/example.conf) 不会被忽略。配置是纯 `KEY=VALUE`，不要添加引号、空格或 shell 表达式；工具不会执行配置内容。

| 配置键 | 说明 |
| --- | --- |
| `SSH_HOST` | 诊断所连接的 SSH 别名 |
| `TUNNEL_HOST` | 可选，隧道专用 SSH 别名；默认使用 `SSH_HOST` |
| `LOCAL_PROXY_PORT` | Mac 本机 HTTP 代理端口，默认 `7897` |
| `REMOTE_PORT` | 远端回环代理端口，默认 `17897` |
| `PROBE_URL` | 连通性探测地址，默认 `https://chatgpt.com/` |
| `MANAGE_TUNNEL` | `yes` 由工具管理隧道；`no` 仅诊断已有隧道 |
| `LAUNCH_LABEL` | 可选的高级设置；默认 `io.github.codex-network.<profile>` |

不同服务器可以使用相同远端端口；同一服务器上的多个隧道应使用不同端口。`TUNNEL_HOST` 必须连接到与 `SSH_HOST` 相同的目标服务器。

修改配置后，如果生成的任务与已有 plist 不一致，工具会提示先 `stop <profile>`，再 `start <profile>` 重新生成。`repair` 只重启已有任务，不更新旧 plist。SSH 配置中的连接端口或 `IdentityAgent` 变化会在下一次 SSH 连接时读取，可用 `repair <profile>` 重连。高级配置 `LAUNCH_LABEL` 可以指向已有外部任务，此时仅支持 `repair` 和 `stop`，`start` 不会覆盖它。

```bash
./codex-network init work --host work-server
./codex-network init lab --host lab-server --remote-port 17898
./codex-network list
./codex-network start all
./codex-network doctor lab
```

默认文件位置：

| 内容 | 位置 | 覆盖目录的环境变量 |
| --- | --- | --- |
| 本地配置 | 项目内 `config/` | `CODEX_NETWORK_CONFIG_DIR` |
| 用户 launchd 任务 | `$HOME/Library/LaunchAgents/io.github.codex-network.<profile>.plist` | `CODEX_NETWORK_LAUNCH_DIR` |
| 隧道日志 | `$HOME/Library/Logs/codex-network/` | `CODEX_NETWORK_LOG_DIR` |

launchd 直接运行 `command -v ssh` 解析出的 SSH 绝对路径，通常是系统 SSH，不依赖仓库路径。启动后移动仓库不会中断已有隧道。请一并保留本地配置，并在后续命令中使用相同的目录覆盖设置。

## 诊断与常见问题

`doctor` 逐项检查本机代理、解析后的 SSH 转发、受管理的 launchd 任务、远端端口监听、VS Code 远端代理设置、远端 HTTP 请求及已运行的 Codex app-server 代理环境。所有匹配的 Codex 进程都应使用预期代理，避免旧进程留下过期设置。

探测发送普通 HTTP GET。HTTP `401` 或 `403` 说明收到了 HTTP 响应，不代表账号已登录、模型可用或流式连接正常；它也不验证具体 Codex 会话。`PROBE_URL` 可按实际网络环境更换为合适的 HTTPS 连通性地址。

| 现象 | 处理方式 |
| --- | --- |
| 本机代理失败 | 确认代理客户端运行、HTTP 端口匹配，本机可以通过它联网 |
| SSH 认证或主机指纹失败 | 先手工 `ssh <别名>`，确认身份、密钥及 agent；不要关闭指纹检查 |
| SSH 转发配置不一致 | 检查 `ssh -G <别名>` 的结果，修正配置或使用专用隧道别名 |
| 远端端口无法绑定 | 检查端口是否已被其他隧道占用；调整 `REMOTE_PORT` 后同步 VS Code 设置 |
| 自动重连持续失败 | 查看日志，并确认远端允许 `RemoteForward`、SSH 认证无需交互 |
| 网络正常但 Codex 仍提示代理错误 | 合并正确的远端 `http.proxy` 设置后执行 `Developer: Reload Window`，再运行诊断 |
| 设置文件检查无法确认 | 按诊断提示人工检查；远端安装 Python 3 可准确解析带注释的 JSON |
| 进程环境无法读取 | 检查当前 SSH 用户是否有权读取该进程；进程检查不依赖 Python |
| 提示已安装任务与当前配置不同 | 执行 `stop <profile>`，再执行 `start <profile>`；`repair` 不更新旧任务 |

修复只作用于配置指定的受管理隧道：检查前提条件、加载或重启对应 launchd 任务，再验证网络。不会修改 SSH 配置、VS Code 设置、登录凭据、会话或数据库，也不会结束其他 SSH 连接。

`MANAGE_TUNNEL=no` 的配置需要通过原有方式启停隧道。批量启停和修复会跳过这些配置，跳过本身不算失败；仍可用 `doctor` 检查其网络。

## 停止与卸载

```bash
./codex-network stop all
```

确认相关任务停止后，可手动删除本工具对应的 plist、本地配置和日志，再删除项目目录。根据实际配置定位文件；不要删除整个 `LaunchAgents` 或日志父目录。若手动合并过 VS Code 代理设置，仅在不再需要该代理时移除对应设置。保留配置时，可用 `start` 再次启用。

## 平台与验证边界

当前面向 macOS 本机和 Linux 远端，不支持在 Windows 或 Linux 本机管理 launchd。支持 macOS 自带 Bash 3.2 的语法；VS Code 和 Codex 的配置存储、进程环境可能随版本变化，诊断输出应结合实际版本判断。自动检查无法替代真实服务器上的端到端验证。

## 开发验证

在项目目录运行语法检查和回归测试；测试需要本机 Python 3，不增加工具本身的运行依赖：

```bash
for script in codex-network ./*.sh; do
  bash -n "$script" || exit 1
done
python3 -m unittest discover -s tests -v
```

CI 配置在 macOS 和 Linux 上执行自动检查；真实 macOS launchd、SSH 服务和代理链路仍需要在自己的环境中验证。

采用 [MIT License](LICENSE)。
