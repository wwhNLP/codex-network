"""离线验证远端诊断，不连接服务器、不读取真实进程或修改 HOME。"""

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SOURCE = (Path(__file__).resolve().parents[1] / "remote-check.sh").read_text(encoding="utf-8")
PROXY = "http://127.0.0.1:17897"
PROBE = "https://chatgpt.com/"
# 只运行明确的解析函数与探针片段，不执行远端脚本的系统发现步骤。
FUNCTIONS = SOURCE.split("\nis_app_server() {", 1)[1].split("\nprocess_count=0", 1)[0]
FUNCTIONS = "is_app_server() {" + FUNCTIONS
JSONC = SOURCE.split("<<'PYTHON'\n", 1)[1].split("\nPYTHON\n", 1)[0]
PROBE_CODE = "probe_code=000\n" + SOURCE.split("\nprobe_code=000\n", 1)[1].split("\nis_app_server()", 1)[0]


class RemoteTests(unittest.TestCase):
    def bash(self, body, *args, data=b"", code=0):
        result = subprocess.run(
            ["/bin/bash", "-c", body, "remote-test", *args], input=data,
            capture_output=True, timeout=10,
        )
        self.assertEqual(result.returncode, code, result.stderr.decode("utf-8", "replace"))
        return result.stdout.decode("utf-8").strip()

    def test_jsonc_comments_trailing_commas_and_decoys(self):
        cases = [
            ('{ // 行注释\n"http.proxy": "' + PROXY + '", /* 块注释 */ }', "correct"),
            ('{"http.proxy":"http://127.0.0.1:1","other":"' + PROXY + '",}', "mismatch"),
            ('{ // "http.proxy":"' + PROXY + '"\n"other":"' + PROXY + '"}', "missing"),
            ('{"http.proxy":"' + PROXY + '", /* 未闭合注释', "unknown"),
            ('{"http.proxy": }', "unknown"),
            ('[]', "unknown"),
            (json.dumps({"http.proxy": PROXY, "other": '转义引号 " // /* , } \\'}), "correct"),
        ]
        with tempfile.TemporaryDirectory(prefix="codex-network-jsonc-") as directory:
            settings = Path(directory) / "settings.json"
            for content, expected in cases:
                with self.subTest(content=content):
                    settings.write_text(content, encoding="utf-8")
                    result = subprocess.run(
                        [sys.executable, "-", str(settings), PROXY], input=JSONC,
                        text=True, capture_output=True, timeout=10,
                    )
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(result.stdout.strip(), expected)

    def test_app_server_identification_excludes_cli(self):
        cases = [
            (["/opt/codex", "app-server"], 0),
            (["codex", "--config", 'key="value"', "app-server"], 0),
            (["codex-x86_64-unknown-linux-musl", "app-server"], 0),
            (["codex", "exec", "app-server"], 1),
            (["codex", "--", "app-server"], 1),
            (["codex", "--config", "app-server", "exec"], 1),
            (["another-program", "app-server"], 1),
            (["codex"], 1),
        ]
        for argv, expected in cases:
            with self.subTest(argv=argv):
                self.bash(FUNCTIONS + "\nis_app_server", data=("\0".join(argv) + "\0").encode(), code=expected)

    def test_proxy_precedence_conflicts_and_no_proxy(self):
        cases = [
            ([name + "=" + PROXY], "correct")
            for name in ("HTTPS_PROXY", "https_proxy", "ALL_PROXY", "all_proxy")
        ]
        cases += [
            (["HTTPS_PROXY=" + PROXY, "ALL_PROXY=http://127.0.0.1:1"], "correct"),
            (["HTTPS_PROXY=http://127.0.0.1:1", "ALL_PROXY=" + PROXY], "stale"),
            (["HTTPS_PROXY=" + PROXY, "https_proxy=http://127.0.0.1:1"], "unknown"),
            (["ALL_PROXY=" + PROXY, "all_proxy=http://127.0.0.1:1"], "unknown"),
            (["HTTPS_PROXY=" + PROXY, "NO_PROXY=*"], "unknown"),
            (["HTTPS_PROXY=" + PROXY, "no_proxy= .ChatGPT.Com,localhost"], "unknown"),
            (["HTTPS_PROXY=" + PROXY, "NO_PROXY=localhost,127.0.0.1"], "correct"),
            (["OTHER=value"], "stale"),
        ]
        program = FUNCTIONS + '\nproxy_url=$1\nprobe_url=$2\nclassify_environment'
        for entries, expected in cases:
            with self.subTest(entries=entries):
                result = self.bash(program, PROXY, PROBE, data=("\0".join(entries) + "\0").encode())
                self.assertEqual(result, expected)

    def test_probe_requires_successful_transport_and_forces_proxy(self):
        # shell 函数完全替代 curl，若关键选项丢失则返回失败，绝不真实联网。
        mock = r'''
curl() {
  [ "$1" = -q ] && [ "$2" = --proxy ] || return 99
  [ "$3" = "$proxy_url" ] && [ "$4" = --noproxy ] && [ -z "$5" ] || return 99
  printf '%s' "$mock_http"
  return "$mock_exit"
}
proxy_url=$1
probe_url=$2
mock_http=$3
mock_exit=$4
'''
        for http, exit_code, expected in (("403", "0", "reachable"), ("200", "0", "reachable"),
                                          ("200", "28", "failed"), ("000", "7", "failed")):
            with self.subTest(http=http, exit_code=exit_code):
                result = self.bash(mock + PROBE_CODE, PROXY, PROBE, http, exit_code)
                values = dict(line.split("=", 1) for line in result.splitlines())
                self.assertEqual(values["PROBE_HTTP"], http)
                self.assertEqual(values["PROBE_CURL_EXIT"], exit_code)
                self.assertEqual(values["PROBE_STATUS"], expected)


if __name__ == "__main__":
    unittest.main()
