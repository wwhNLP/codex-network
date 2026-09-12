"""离线验证配置、诊断结果和隧道副作用边界，不连接真实服务器。"""

import json
import os
from pathlib import Path
import plistlib
import shlex
import stat
import subprocess
import sys
import tempfile
import unittest


PROJECT = Path(__file__).resolve().parents[1]
HEALTHY_REMOTE = {
    "REMOTE_PROTOCOL": "1",
    "REMOTE_CONNECTED": "1",
    "REMOTE_LISTENER": "present",
    "VSCODE_PROXY": "correct",
    "PROBE_HTTP": "403",
    "PROBE_CURL_EXIT": "0",
    "PROBE_STATUS": "reachable",
    "CODEX_STATE": "correct",
    "CODEX_TOTAL": "2",
    "CODEX_CORRECT": "2",
    "CODEX_STALE": "0",
    "CODEX_UNKNOWN": "0",
}

# 所有可能接触网络或系统任务的外部命令都由这个本地夹具替代。
MOCK_COMMAND = r'''
import json
import os
from pathlib import Path
import plistlib
import sys

name = Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ["MOCK_CALL_LOG"], "a", encoding="utf-8") as log:
    log.write(json.dumps([name, args]) + "\n")

if name == "ssh":
    if "-G" in args:
        print(os.environ.get("MOCK_SSH_CONFIG", "hostname my-server"))
        sys.exit(0)
    if args[-1] == "true":
        sys.exit(int(os.environ.get("MOCK_SSH_LOGIN_EXIT", "0")))
    if args[-1].startswith("bash -s -- "):
        sys.stdin.read()
        print(os.environ["MOCK_REMOTE_RESPONSE"])
        sys.exit(int(os.environ.get("MOCK_REMOTE_EXIT", "0")))
    sys.exit(97)
elif name == "curl":
    print(os.environ.get("MOCK_CURL_CODE", "403"), end="")
    sys.exit(int(os.environ.get("MOCK_CURL_EXIT", "0")))
elif name == "uname":
    print(os.environ.get("MOCK_PLATFORM", "Darwin"))
elif name == "plutil":
    try:
        with open(args[-1], "rb") as source:
            plistlib.load(source)
    except Exception:
        sys.exit(1)
elif name == "launchctl":
    state_file = Path(os.environ["MOCK_LAUNCH_STATE"])
    state = json.loads(state_file.read_text()) if state_file.exists() else {}
    operation = args[0]
    if operation == "print":
        if not state.get("loaded"):
            sys.exit(113)
        print("state = running")
        sys.exit(0)
    if operation == "bootstrap":
        state["loaded"] = True
    elif operation == "bootout":
        state["loaded"] = False
    elif operation == "disable":
        state["disabled"] = True
    elif operation == "enable":
        state["disabled"] = False
    elif operation == "kickstart":
        if not state.get("loaded"):
            sys.exit(113)
    else:
        sys.exit(97)
    state_file.write_text(json.dumps(state))
elif name != "sleep":
    sys.exit(97)
'''


class CliTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="codex-network-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.config = self.root / "config"
        self.launch = self.root / "launch agents"
        self.logs = self.root / "logs & <中文>"
        self.bin = self.root / "bin"
        self.config.mkdir()
        self.bin.mkdir()
        self.calls_file = self.root / "calls.jsonl"
        self.state_file = self.root / "launch-state.json"
        self.env = os.environ.copy()
        self.env.update({
            "PATH": str(self.bin) + os.pathsep + os.environ.get("PATH", ""),
            "CODEX_NETWORK_CONFIG_DIR": str(self.config),
            "CODEX_NETWORK_LAUNCH_DIR": str(self.launch),
            "CODEX_NETWORK_LOG_DIR": str(self.logs),
            "MOCK_CALL_LOG": str(self.calls_file),
            "MOCK_LAUNCH_STATE": str(self.state_file),
            "SSH_AUTH_SOCK": str(self.root / "agent & <socket>"),
        })
        self.remote_status()
        for name in ("ssh", "curl", "launchctl", "uname", "plutil", "sleep"):
            command = self.bin / name
            command.write_text("#!" + sys.executable + "\n" + MOCK_COMMAND)
            command.chmod(0o700)
        # macOS 上的所有嵌套脚本也使用系统自带的 Bash 3.2。
        (self.bin / "bash").symlink_to("/bin/bash")

    def remote_status(self, **changes):
        status = dict(HEALTHY_REMOTE, **changes)
        self.env["MOCK_REMOTE_RESPONSE"] = "\n".join(
            key + "=" + value for key, value in status.items()
        )

    def run_cli(self, *args, code=0, script="codex-network"):
        result = subprocess.run(
            ["/bin/bash", str(PROJECT / script), *args],
            cwd=self.root,
            env=self.env,
            input="",
            text=True,
            capture_output=True,
            timeout=15,
        )
        self.assertEqual(result.returncode, code, result.stdout + result.stderr)
        return result.stdout + result.stderr

    def write_config(self, name="dev", **changes):
        values = {
            "SSH_HOST": "my-server", "LOCAL_PROXY_PORT": "7897",
            "REMOTE_PORT": "17897", "PROBE_URL": "https://chatgpt.com/",
            "MANAGE_TUNNEL": "yes", **changes,
        }
        path = self.config / (name + ".conf")
        path.write_text("".join(key + "=" + value + "\n" for key, value in values.items()))
        return path

    def calls(self, name=None):
        records = [json.loads(line) for line in self.calls_file.read_text().splitlines()] \
            if self.calls_file.exists() else []
        return [args for command, args in records if command == name] if name else records

    def clear_calls(self):
        self.calls_file.write_text("")

    def assert_no_management(self):
        self.assertFalse(self.calls("ssh"))
        self.assertFalse(self.calls("curl"))
        self.assertFalse(self.calls("launchctl"))
        self.assertFalse(self.launch.exists())
        self.assertFalse(self.logs.exists())

    def launch_operations(self):
        return [args[0] for args in self.calls("launchctl")]

    def test_help_and_empty_configuration(self):
        self.run_cli("help")
        for command in ("init", "start", "doctor", "repair", "stop"):
            with self.subTest(command=command):
                self.run_cli(command, "--help")
        self.run_cli("doctor", code=2)
        self.assert_no_management()

    def test_init_private_configuration_and_no_overwrite(self):
        self.run_cli("init", "dev", "--host", "my-server", "--local-port", "7897", "--remote-port", "17897")
        path = self.config / "dev.conf"
        original = path.read_bytes()
        self.assertIn(b"SSH_HOST=my-server\n", original)
        self.assertIn(b"REMOTE_PORT=17897\n", original)
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        self.run_cli("init", "dev", "--host", "other-server", code=2)
        self.assertEqual(path.read_bytes(), original)
        self.assertIn("my-server", self.run_cli("list"))
        self.assert_no_management()

    def test_init_rejects_invalid_names_hosts_and_ports(self):
        for name in ("../escape", "all", "example", "two names"):
            with self.subTest(name=name):
                self.run_cli("init", name, "--host", "my-server", code=2)
        for port in ("0", "01", "65536", "99999999999999999999999", "-1", "1+1"):
            for flag in ("--local-port", "--remote-port"):
                with self.subTest(port=port, flag=flag):
                    self.run_cli("init", "dev", "--host", "my-server", flag, port, code=2)
        for host in ("-oProxyCommand=anything", "user@host;touch", "two hosts"):
            with self.subTest(host=host):
                self.run_cli("init", "dev", "--host", host, code=2)
        self.assertEqual(list(self.config.iterdir()), [])
        self.assert_no_management()

    def test_init_accepts_port_boundaries(self):
        self.run_cli("init", "dev", "--host", "user@example.invalid", "--local-port", "1", "--remote-port", "65535")
        self.assertIn("65535", self.run_cli("list"))

    def test_init_does_not_follow_existing_symlink(self):
        destination = self.root / "untouched.conf"
        destination.write_text("保留原内容")
        (self.config / "dev.conf").symlink_to(destination)
        self.run_cli("init", "dev", "--host", "my-server", code=2)
        self.assertEqual(destination.read_text(), "保留原内容")
        self.assert_no_management()

    def test_configuration_is_data_not_shell(self):
        marker = self.root / "should-not-exist"
        self.write_config(PROBE_URL="https://example.invalid/$(touch${IFS}" + str(marker) + ")")
        self.run_cli("list")
        self.assertFalse(marker.exists())
        self.write_config(SSH_HOST="$(touch " + str(marker) + ")")
        self.run_cli("list", code=2)
        self.assertFalse(marker.exists())
        self.assert_no_management()

    def test_duplicate_unknown_and_shell_style_config_rejected(self):
        for extra in ("SSH_HOST=other\n", "UNKNOWN=value\n", "export REMOTE_PORT=18000\n"):
            with self.subTest(extra=extra):
                path = self.write_config()
                path.write_text(path.read_text() + extra)
                self.run_cli("doctor", "dev", code=2)
        self.assert_no_management()

    def test_batch_validates_all_configs_before_side_effects(self):
        self.write_config("aaa")
        self.write_config("zzz", REMOTE_PORT="65536")
        self.run_cli("start", "all", code=2)
        self.assert_no_management()

    def test_dry_run_never_connects_or_creates_launch_files(self):
        self.write_config()
        self.env["MOCK_PLATFORM"] = "Linux"
        for command in ("start", "repair", "stop"):
            with self.subTest(command=command):
                self.assertIn("17897", self.run_cli(command, "dev", "--dry-run"))
        self.assert_no_management()

    def test_unmanaged_target_skips_automatic_operations(self):
        self.write_config(MANAGE_TUNNEL="no")
        for command in ("start", "repair", "stop"):
            self.run_cli(command, "all")
        self.assert_no_management()

    def test_start_generates_valid_private_plist_and_stop_preserves_it(self):
        self.write_config()
        self.run_cli("start", "dev")
        plist_path = self.launch / "io.github.codex-network.dev.plist"
        original = plist_path.read_bytes()
        plist = plistlib.loads(original)
        args = plist["ProgramArguments"]
        self.assertEqual(args[0], str(self.bin / "ssh"))
        self.assertIn("127.0.0.1:17897:127.0.0.1:7897", args)
        self.assertIn("ExitOnForwardFailure=yes", args)
        self.assertIn("ControlPath=none", args)
        self.assertIn("ForkAfterAuthentication=no", args)
        self.assertIn("RemoteCommand=none", args)
        self.assertIn("-R", args)
        # 临时 agent socket 不能写入持久任务，下次登录应继承当前会话。
        self.assertNotIn("SSH_AUTH_SOCK", plist["EnvironmentVariables"])
        self.assertEqual(Path(plist["StandardErrorPath"]).parent, self.logs)
        self.assertEqual(stat.S_IMODE(plist_path.stat().st_mode), 0o600)
        self.assertEqual(self.launch_operations(), ["print", "enable", "bootstrap"])
        self.clear_calls()
        self.run_cli("start", "dev")
        self.assertEqual(self.launch_operations(), ["print", "enable", "kickstart"])
        self.assertNotIn("-k", self.calls("launchctl")[-1])
        self.clear_calls()
        self.run_cli("repair", "dev")
        self.assertEqual(self.launch_operations(), ["print", "enable", "kickstart"])
        self.assertIn("-k", self.calls("launchctl")[-1])
        self.clear_calls()
        self.run_cli("stop", "dev")
        self.assertEqual(self.launch_operations(), ["print", "bootout", "disable"])
        self.assertEqual(plist_path.read_bytes(), original)
        self.assertTrue(json.loads(self.state_file.read_text())["disabled"])

    def test_repair_reloads_existing_unloaded_plist(self):
        self.write_config()
        self.run_cli("start", "dev")
        self.run_cli("stop", "dev")
        self.clear_calls()
        self.run_cli("repair", "dev")
        self.assertEqual(self.launch_operations(), ["print", "enable", "bootstrap"])

    def test_changed_port_requires_stop_start_and_keeps_old_plist(self):
        self.write_config()
        self.run_cli("start", "dev")
        path = self.launch / "io.github.codex-network.dev.plist"
        original = path.read_bytes()
        self.write_config(REMOTE_PORT="18897")
        for command in ("repair", "start"):
            self.clear_calls()
            self.assertIn("stop", self.run_cli(command, "dev", code=1))
            self.assertEqual(self.launch_operations(), ["print"])
            self.assertEqual(path.read_bytes(), original)
        self.run_cli("stop", "dev")
        self.run_cli("start", "dev")
        self.assertIn("127.0.0.1:18897:127.0.0.1:7897", plistlib.loads(path.read_bytes())["ProgramArguments"])

    def test_start_preserves_unowned_plist(self):
        self.write_config()
        self.launch.mkdir()
        path = self.launch / "io.github.codex-network.dev.plist"
        original = plistlib.dumps({"Label": "another.tool"})
        path.write_bytes(original)
        self.run_cli("start", "dev", code=1)
        self.assertEqual(path.read_bytes(), original)
        self.assertEqual(self.launch_operations(), ["print"])

    def test_proxy_ssh_and_forward_errors_do_not_start_service(self):
        self.write_config()
        scenarios = (
            {"MOCK_CURL_EXIT": "7", "MOCK_CURL_CODE": "000"},
            {"MOCK_CURL_CODE": "407"},
            {"MOCK_SSH_LOGIN_EXIT": "255"},
            {"MOCK_SSH_CONFIG": "remoteforward 0.0.0.0:17897 127.0.0.1:7897"},
            {"MOCK_SSH_CONFIG": "localforward 8080 localhost:80"},
        )
        for changes in scenarios:
            with self.subTest(changes=changes):
                self.env.update(changes)
                self.clear_calls()
                self.run_cli("start", "dev", code=1)
                self.assertEqual(self.launch_operations(), ["print"])
                self.assertFalse(self.launch.exists())
                for key in changes:
                    self.env.pop(key)

    def test_matching_existing_remote_forward_is_not_duplicated(self):
        self.write_config()
        self.env["MOCK_SSH_CONFIG"] = "remoteforward [127.0.0.1]:17897 [127.0.0.1]:7897"
        self.run_cli("start", "dev")
        path = self.launch / "io.github.codex-network.dev.plist"
        self.assertNotIn("-R", plistlib.loads(path.read_bytes())["ProgramArguments"])

    def test_doctor_checks_transport_without_claiming_authentication(self):
        self.write_config(MANAGE_TUNNEL="no")
        output = self.run_cli("doctor", "dev")
        self.assertIn("403", output)
        self.assertIn("不代表", output)
        self.assertFalse(self.calls("launchctl"))
        self.remote_status(CODEX_STATE="mixed", CODEX_CORRECT="1", CODEX_STALE="1")
        output = self.run_cli("doctor", "dev")
        self.assertIn("不一致", output)
        self.assertIn("代理匹配 1", output)
        self.assertIn("不匹配 1", output)

    def test_doctor_fails_incomplete_ssh_listener_and_transport(self):
        self.write_config(MANAGE_TUNNEL="no")
        for changes in (
            {"REMOTE_PROTOCOL": ""}, {"REMOTE_CONNECTED": "0"},
            {"REMOTE_LISTENER": "missing"}, {"PROBE_HTTP": "500"},
            {"PROBE_CURL_EXIT": "7"}, {"PROBE_STATUS": "failed"},
        ):
            with self.subTest(changes=changes):
                self.remote_status(**changes)
                self.run_cli("doctor", "dev", code=1)
        self.env["MOCK_REMOTE_RESPONSE"] = "private-authentication-output"
        self.env["MOCK_REMOTE_EXIT"] = "255"
        self.assertNotIn("private-authentication-output", self.run_cli("doctor", "dev", code=1))

    def test_doctor_reports_unavailable_optional_checks_as_warnings(self):
        self.write_config(MANAGE_TUNNEL="no")
        self.remote_status(
            REMOTE_LISTENER="unknown", VSCODE_PROXY="unknown",
            PROBE_STATUS="unknown", PROBE_CURL_EXIT="127", PROBE_HTTP="000",
            CODEX_STATE="unknown", CODEX_CORRECT="0", CODEX_UNKNOWN="2",
        )
        output = self.run_cli("doctor", "dev")
        self.assertIn("[警告]", output)
        self.assertIn("0 个失败", output)

    def test_probe_url_is_one_quoted_remote_argument(self):
        url = "https://example.invalid/path?a='quoted'&b=$(false)"
        self.write_config(PROBE_URL=url, MANAGE_TUNNEL="no")
        self.run_cli("doctor", "dev")
        command = next(args[-1] for args in self.calls("ssh") if args[-1].startswith("bash -s"))
        self.assertEqual(shlex.split(command), ["bash", "-s", "--", "17897", "http://127.0.0.1:17897", url])

    def test_start_does_not_report_success_for_inconsistent_probe(self):
        self.write_config()
        for changes in (
            {"REMOTE_CONNECTED": "0"}, {"PROBE_HTTP": "500"}, {"PROBE_CURL_EXIT": "7"},
        ):
            with self.subTest(changes=changes):
                self.remote_status(**changes)
                self.run_cli("start", "dev", code=1)

    def test_failed_remote_probe_retries_and_returns_failure(self):
        self.write_config()
        self.remote_status(REMOTE_LISTENER="missing", PROBE_STATUS="failed")
        self.run_cli("start", "dev", code=1)
        probes = [args for args in self.calls("ssh") if args[-1].startswith("bash -s")]
        self.assertEqual(len(probes), 3)
        self.assertEqual(len(self.calls("sleep")), 2)


if __name__ == "__main__":
    unittest.main()
