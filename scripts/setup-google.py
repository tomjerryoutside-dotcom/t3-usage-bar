#!/usr/bin/env python3
"""安装本机反重力额度助手，可选准备 Google One 扩展。"""

import argparse
import json
import os
import platform
import plistlib
import re
import secrets
import socket
import subprocess
import sys
import tempfile
from pathlib import Path


LABEL = "local.t3-usage-bar.antigravity-quota"
URL = "http://127.0.0.1:59417/antigravity"


def write_file(path, data):
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as temporary:
        draft = Path(temporary.name)
        try:
            temporary.write(data)
            temporary.flush()
            os.replace(draft, path)
        finally:
            draft.unlink(missing_ok=True)


def prepare(repo, target, agent_file, python_path, chrome):
    target.mkdir(parents=True, exist_ok=True, mode=0o700)
    source = target / "quota_source.py"
    write_file(source, (repo / "integrations/antigravity/quota_source.py").read_bytes())

    agent_file.parent.mkdir(parents=True, exist_ok=True)
    agent = {
        "Label": LABEL,
        "ProgramArguments": [python_path, "-B", str(source)],
        "WorkingDirectory": str(target),
        "ProcessType": "Background",
        "RunAtLoad": True,
        "KeepAlive": True,
        "ThrottleInterval": 15,
    }
    proxy_settings = {
        key: os.environ[key] for key in
        ("HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY", "SSL_CERT_FILE", "SSL_CERT_DIR")
        if key in os.environ
    }
    if proxy_settings:
        agent["EnvironmentVariables"] = proxy_settings
    write_file(agent_file, plistlib.dumps(agent))

    if not chrome:
        return None

    key_file = target / "google-one-sync.key"
    if key_file.exists():
        key = key_file.read_text().strip()
        if not re.fullmatch(r"[a-f0-9]{64}", key):
            raise ValueError("本机扩展密钥格式无效，请检查现有安装。")
    else:
        key = secrets.token_hex(32)
        write_file(key_file, (key + "\n").encode("utf-8"))

    extension = target / "Google One Sync"
    extension.mkdir(exist_ok=True, mode=0o700)
    for name in ("manifest.json", "sync.js"):
        write_file(extension / name, (repo / "integrations/google-one-sync" / name).read_bytes())
    config = (
        f"export const endpoint = {json.dumps(URL + '/plan')};\n"
        f"export const syncKey = {json.dumps(key)};\n"
    )
    write_file(extension / "local-config.js", config.encode("utf-8"))
    return extension


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--chrome", action="store_true", help="同时准备 Google One 套餐同步扩展")
    args = parser.parse_args()
    if platform.system() != "Darwin" or os.getuid() == 0:
        parser.exit(1, "请在 Mac 上使用当前登录的普通用户运行。\n")
    if sys.version_info < (3, 9):
        parser.exit(1, "需要 Python 3.9 或更新版本。\n")

    repo = Path(__file__).resolve().parents[1]
    user = Path.home()
    target = user / "Library/Application Support/T3 Usage Bar/Antigravity"
    agent_file = user / "Library/LaunchAgents" / f"{LABEL}.plist"
    domain = f"gui/{os.getuid()}"
    job = f"{domain}/{LABEL}"
    running = subprocess.run(
        ["/bin/launchctl", "print", job], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
    ).returncode == 0

    if not running:
        try:
            with socket.create_connection(("127.0.0.1", 59417), timeout=0.5):
                parser.exit(1, "59417 端口已有服务。若 T3 已接入本机反重力额度源，可直接沿用。\n")
        except OSError:
            pass

    try:
        extension = prepare(repo, target, agent_file, sys.executable, args.chrome)
    except (OSError, ValueError) as error:
        parser.exit(1, f"{error}\n")

    if running:
        subprocess.run(["/bin/launchctl", "bootout", job], check=True)
    subprocess.run(["/bin/launchctl", "bootstrap", domain, str(agent_file)], check=True)
    print(f"本机额度地址 {URL}")
    if extension is not None:
        print(f"Chrome 扩展目录 {extension}")


if __name__ == "__main__":
    main()
