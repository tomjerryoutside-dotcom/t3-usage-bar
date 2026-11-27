#!/usr/bin/python3
"""Expose the managed Antigravity CLI's subscription summary to T3 on loopback."""

import datetime as dt
import hashlib
import hmac
import json
import math
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

T3_HOME = Path.home() / ".t3"
INSTANCE = "antigravity"
PROFILE = T3_HOME / "userdata/providers/antigravity" / hashlib.sha256(INSTANCE.encode()).hexdigest()
CREDENTIAL = PROFILE / "antigravity-acp/antigravity-oauth-token"
MANAGED = T3_HOME / f"tools/antigravity-acp/darwin-{os.uname().machine}"
BIND_ADDRESS = "127.0.0.1"
PORT = 59417
ROUTE = "/antigravity"
REFRESH_AFTER = 90
STALE_LIMIT = 10 * 60
RETRY_AFTER = 20
FIRST_READ_WAIT = 7
PLAN_RECORD = Path(__file__).with_name("verified-plan.json")
PLAN_SYNC_KEY = Path(__file__).with_name("google-one-sync.key")
PLAN_LABELS = {"Google AI Plus", "Google AI Pro", "Google AI Ultra 5x", "Google AI Ultra 20x"}


class QuotaUnavailable(Exception):
    pass


def profile_identity():
    settings = json.loads((T3_HOME / "userdata/settings.json").read_text())
    provider = settings.get("providerInstances", {}).get(INSTANCE, {})
    config = provider.get("config") or {}
    if (provider.get("driver") != INSTANCE
            or not provider.get("enabled", True)
            or config.get("authMethod", "oauth-personal") != "oauth-personal"
            or config.get("binaryPath")
            or not any(item.get("name") == "AGY_CLI_FORCE_FILE_TOKEN_STORAGE"
                       and item.get("value") in ("true", "1")
                       for item in provider.get("environment", []))):
        raise QuotaUnavailable("The managed Google subscription profile is unavailable")
    stored = json.loads(CREDENTIAL.read_text())
    email = stored.get("id_token_email")
    if stored.get("auth_method") != "consumer" or not isinstance(email, str) or not email.strip():
        raise QuotaUnavailable("The managed Google subscription profile is unavailable")
    return hashlib.sha256(email.strip().casefold().encode()).digest()


def verified_plan(identity):
    try:
        record = json.loads(PLAN_RECORD.read_text())
    except (OSError, ValueError):
        return None
    if not isinstance(record, dict) or record.get("account") != identity.hex():
        return None
    plan = record.get("plan")
    return plan if isinstance(plan, str) and plan in PLAN_LABELS else None


def update_verified_plan(record):
    if not isinstance(record, dict):
        return False
    account, plan = record.get("account"), record.get("plan")
    if not isinstance(account, str) or account != profile_identity().hex():
        return False
    if not isinstance(plan, str) or plan not in PLAN_LABELS:
        return False
    verified = {
        "account": account,
        "plan": plan,
        "verifiedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
    }
    with tempfile.NamedTemporaryFile("w", dir=PLAN_RECORD.parent, delete=False) as output:
        draft = Path(output.name)
        try:
            json.dump(verified, output)
            output.write("\n")
            output.flush()
            os.replace(draft, PLAN_RECORD)
        finally:
            draft.unlink(missing_ok=True)
    return True


def managed_executable():
    release = json.loads((MANAGED / "active.json").read_text())["releaseId"]
    if not re.fullmatch(r"[0-9a-f]{64}", release):
        raise QuotaUnavailable("The managed runtime record is invalid")
    folder = MANAGED / "versions" / release
    record = json.loads((folder / ".install-complete.json").read_text())
    if record.get("executable", {}).get("name") != "antigravity":
        raise QuotaUnavailable("The managed runtime executable is unavailable")
    return folder / "antigravity"


def usage_windows(receipt):
    command = receipt.get("command") or {}
    if (receipt.get("status") != "SUCCESS"
            or receipt.get("num_turns") != 0
            or (receipt.get("usage") or {}).get("total_tokens", 0) != 0
            or command.get("name", "").lstrip("/") != "usage"):
        raise QuotaUnavailable("The CLI did not return a read-only usage receipt")
    windows = {}
    for group in (command.get("data") or {}).get("groups", []):
        for bucket in group.get("buckets", []):
            fraction = bucket.get("remaining_fraction")
            bucket_id = bucket.get("id")
            if (not isinstance(bucket_id, str) or not bucket_id.strip()
                    or not isinstance(fraction, (float, int)) or isinstance(fraction, bool)
                    or not math.isfinite(fraction) or not 0 <= fraction <= 1):
                continue
            period = bucket.get("window")
            kind, suffix = {
                "5h": ("session", "5小时"),
                "weekly": ("weekly", "周额度"),
            }.get(period, ("other", bucket.get("name") or "额度"))
            family = group.get("name") or INSTANCE
            family = {"gemini models": "Gemini", "claude and gpt models": "Claude/GPT"}.get(
                family.casefold(), family)
            window = {
                "id": bucket_id,
                "kind": kind,
                "label": f"{family} {suffix}",
                "usedPercent": 100 * (1 - fraction),
            }
            if isinstance(bucket.get("reset_time"), str):
                try:
                    reset = dt.datetime.fromisoformat(bucket["reset_time"].replace("Z", "+00:00"))
                    if reset.tzinfo is not None and reset > dt.datetime.now(dt.timezone.utc):
                        window["resetsAt"] = reset.astimezone(dt.timezone.utc).isoformat(
                            timespec="seconds").replace("+00:00", "Z")
                except ValueError:
                    pass
            windows[bucket_id] = window
    if not windows:
        raise QuotaUnavailable("The CLI returned no usable quota windows")
    return sorted(windows.values(), key=lambda w: (
        not w["id"].startswith("gemini-"), w["label"].rsplit(" ", 1)[0],
        {"session": 0, "weekly": 1}.get(w["kind"], 2), w["id"],
    ))


def read_quota(timeout):
    env = {key: val for key, val in os.environ.items() if key in {
        "HOME", "USER", "LOGNAME", "PATH", "LANG", "LC_ALL", "TMPDIR",
        "HTTPS_PROXY", "HTTP_PROXY", "NO_PROXY", "SSL_CERT_FILE", "SSL_CERT_DIR",
    }}
    env.update(
        AGY_CLI_FORCE_FILE_TOKEN_STORAGE="true",
        AGY_CLI_DISABLE_AUTO_UPDATE="true",
        BROWSER="/usr/bin/false",
        SSH_CONNECTION="127.0.0.1 0 127.0.0.1 0",
        TERM="dumb",
    )
    result = subprocess.run(
        [str(managed_executable()), "--gemini_dir", str(PROFILE),
         "--app_data_dir", "antigravity-acp", "--print", "/usage",
         "--output-format", "json", "--log-file", "/dev/null", "--print-timeout", "19s"],
        env=env, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=timeout,
    )
    if result.returncode != 0 or not result.stdout:
        raise QuotaUnavailable(f"The Antigravity CLI returned exit {result.returncode}")
    return {
        "version": 1,
        "accounts": [{
            "id": INSTANCE,
            "label": "Antigravity",
            "providerInstanceId": INSTANCE,
            "windows": usage_windows(json.loads(result.stdout)),
        }],
    }


class Source:
    def __init__(self):
        self.lock = threading.Lock()
        self.cached = None
        self.task = None
        self.attempted = None

    def refresh(self, identity):
        try:
            receipt = read_quota(22)
            if profile_identity() != identity:
                return
        except (QuotaUnavailable, OSError, ValueError, KeyError, TypeError,
                AttributeError, subprocess.SubprocessError):
            return
        with self.lock:
            self.cached = identity, time.time(), receipt

    def current(self, identity):
        if self.cached is not None and self.cached[0] == identity:
            saved_at, receipt = self.cached[1:]
            age = time.time() - saved_at
            if 0 <= age < STALE_LIMIT:
                if age < REFRESH_AFTER:
                    return age, receipt
                stamp = dt.datetime.fromtimestamp(saved_at).strftime("%H:%M")
                account = dict(receipt["accounts"][0], label=f"Antigravity · 上次读取 {stamp}")
                return age, dict(receipt, accounts=[account])
        return None

    def consider_refresh(self, identity, current):
        if current is not None and current[0] < REFRESH_AFTER:
            return
        if self.task is not None and self.task.is_alive():
            return
        now = time.time()
        if self.attempted is not None and self.attempted[0] == identity:
            if 0 <= now - self.attempted[1] < RETRY_AFTER:
                return
        self.attempted = identity, now
        self.task = threading.Thread(target=self.refresh, args=(identity,), daemon=True)
        self.task.start()

    def warm(self):
        try:
            identity = profile_identity()
        except (QuotaUnavailable, OSError, ValueError, TypeError, AttributeError):
            return
        with self.lock:
            self.consider_refresh(identity, self.current(identity))

    def read(self):
        identity = profile_identity()
        with self.lock:
            current = self.current(identity)
            self.consider_refresh(identity, current)
            task = self.task
        if current is not None:
            return current[1], identity
        if task is not None:
            task.join(FIRST_READ_WAIT)
        updated_identity = profile_identity()
        with self.lock:
            current = self.current(updated_identity)
        if current is not None:
            return current[1], updated_identity
        raise QuotaUnavailable("Waiting for a fresh Antigravity quota reading")


class Handler(BaseHTTPRequestHandler):
    source = Source()

    def do_GET(self):
        if self.path != ROUTE or self.headers.get("Host") != f"{BIND_ADDRESS}:{PORT}":
            self.send_json(404, {"error": "Not found"})
            return
        try:
            payload, identity = self.source.read()
        except QuotaUnavailable as error:
            self.send_json(503, {"error": str(error)})
        except (OSError, ValueError, KeyError, TypeError, AttributeError):
            self.send_json(503, {"error": "Antigravity quota is temporarily unavailable"})
        else:
            self.send_json(200, payload, plan=verified_plan(identity))

    def do_POST(self):
        if self.path != f"{ROUTE}/plan" or self.headers.get("Host") != f"{BIND_ADDRESS}:{PORT}":
            self.send_json(404, {"error": "Not found"})
            return
        try:
            expected = PLAN_SYNC_KEY.read_text().strip()
            supplied = self.headers.get("X-T3-Plan-Sync", "")
            if not expected or not hmac.compare_digest(expected.encode(), supplied.encode()):
                self.send_json(403, {"error": "Plan sync denied"})
                return
            length = int(self.headers.get("Content-Length", "0"))
            if not 0 < length <= 512:
                self.send_json(400, {"error": "Invalid plan length"})
                return
            self.connection.settimeout(4)
            record = json.loads(self.rfile.read(length))
            if not update_verified_plan(record):
                self.send_json(409, {"error": "Plan or Google account does not match"})
                return
        except (QuotaUnavailable, OSError, ValueError, TypeError):
            self.send_json(400, {"error": "Plan sync could not be processed"})
            return
        self.send_json(200, {"updated": True})

    def send_json(self, status, payload, plan=None):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        try:
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            if plan is not None:
                self.send_header("X-Antigravity-Plan", plan)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, *_args):
        pass


if __name__ == "__main__":
    if sys.argv[1:] == ["--probe"]:
        current_identity = profile_identity()
        quota = read_quota(22)
        if profile_identity() != current_identity:
            raise SystemExit("The Google account changed during the quota read")
        print(json.dumps(quota, ensure_ascii=False))
    else:
        with ThreadingHTTPServer((BIND_ADDRESS, PORT), Handler) as server:
            Handler.source.warm()
            server.serve_forever()
