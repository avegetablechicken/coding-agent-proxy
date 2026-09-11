#!/usr/bin/env python3
"""Offline integration: real listener, URLSession CONNECT, hot reload, fail-closed routing.
Uses only synthetic credentials and loopback sockets. Run after swift build.
"""
import http.client
import json
import pathlib
import socket
import socketserver
import subprocess
import tempfile
import threading
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]

class Probe(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True
    def __init__(self):
        self.requests = []
        super().__init__(("127.0.0.1", 0), Handler)
        threading.Thread(target=self.serve_forever, daemon=True).start()

class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.settimeout(3)
        data = self.request.recv(65536)
        self.server.requests.append(data)
        self.request.sendall(b"HTTP/1.1 502 Test Proxy Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")


def main():
    probes = [Probe(), Probe()]
    a, b = probes
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    process = None
    try:
        with tempfile.TemporaryDirectory(prefix="coding-agent-proxy-test-") as temp:
            temp = pathlib.Path(temp)
            auth = temp / "auth.json"
            config = temp / "config.yaml"
            def login(account, token):
                staged = temp / "auth.next"
                staged.write_text(json.dumps({"tokens": {"account_id": account, "access_token": token}}))
                staged.replace(auth)
            def configure(a_proxy):
                value = f'''listen_port: {port}
auth_file: "{auth}"
upstream_base_url: "https://upstream.invalid/backend-api/codex"
request_timeout_seconds: 3
proxies:
  us: "http://127.0.0.1:{a_proxy}"
  jp: "http://127.0.0.1:{b.server_address[1]}"
accounts:
  account-a: us
  account-b: jp
'''
                staged = temp / "config.next"
                staged.write_text(value)
                staged.replace(config)
            def request(token="token-a", account=None, path="/responses"):
                conn = http.client.HTTPConnection("127.0.0.1", port, timeout=8)
                headers = {"Authorization": "Bearer " + token, "Content-Type": "application/json"}
                if account is not None:
                    headers["ChatGPT-Account-Id"] = account
                conn.request("GET" if path == "/health" else "POST", path, body=b'{"private":"secret-body"}', headers=headers)
                response = conn.getresponse()
                result = response.status, response.read()
                conn.close()
                return result
            login("account-a", "token-a")
            configure(a.server_address[1])
            subprocess.run([str(ROOT / ".build/debug/coding-agent-proxy"), "--config", str(config), "--check"], check=True)
            process = subprocess.Popen([str(ROOT / ".build/debug/coding-agent-proxy"), "--config", str(config)], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
            for _ in range(100):
                try:
                    assert request(path="/health")[0] == 200
                    break
                except OSError:
                    time.sleep(0.05)
            else:
                raise AssertionError("Listener did not start")
            assert request(token="wrong")[0] == 401
            assert not a.requests and not b.requests
            result = request(path="/responses?private_query=secret-query")
            assert result[0] == 502, result
            assert a.requests and not b.requests, f"account-a must use US proxy: response={result!r}"
            assert a.requests[0].startswith(b"CONNECT "), a.requests[0]
            assert b"token-a" not in a.requests[0], "Bearer must not leak into CONNECT"
            previous_a = len(a.requests)
            login("account-b", "token-b")
            assert request(token="token-a")[0] == 401
            assert request(token="token-b", account="account-a")[0] == 409
            assert request(token="token-b", account="account-b")[0] == 502
            assert b.requests and len(a.requests) == previous_a
            total = len(a.requests) + len(b.requests)
            login("unmapped", "token-c")
            assert request(token="token-c")[0] == 502
            assert total == len(a.requests) + len(b.requests)
            login("account-a", "token-a")
            configure(b.server_address[1])
            previous_b = len(b.requests)
            assert request()[0] == 502
            assert len(b.requests) > previous_b, "YAML reload must change the chosen proxy"
            with socket.socket() as unused:
                unused.bind(("127.0.0.1", 0))
                dead_port = unused.getsockname()[1]
            configure(dead_port)
            before_failure = len(a.requests) + len(b.requests)
            assert request()[0] == 502
            assert len(a.requests) + len(b.requests) == before_failure, "No fallback to another proxy"
            config.write_text("invalid: [")
            assert request()[0] == 502
            assert request(path="/health")[0] == 200
            log_path = temp / "logs/proxy.log"
            for _ in range(100):
                records = [json.loads(line) for line in log_path.read_text().splitlines()]
                terminal = [r for r in records if r["event"] in ("request_finished", "request_failed", "request_rejected")]
                if len(terminal) == 9:
                    break
                time.sleep(0.01)
            assert len(terminal) == 9
            current = next(r for r in records if r["event"] == "current_route")
            assert current["account_id"] == "account-a" and current["proxy"] == "us"
            routes = [r for r in records if r["event"] == "route_selected"]
            assert [(r["account_id"], r["proxy"]) for r in routes] == [("account-a", "us"), ("account-b", "jp"), ("account-a", "us"), ("account-a", "us")]
            assert all(r.get("request_id") and r.get("duration_ms") is not None for r in terminal)
            assert {r["status"] for r in terminal} == {"401", "409", "502"}
            raw_log = log_path.read_text()
            for secret in ["token-a", "token-b", "token-c", "secret-query", "secret-body"]:
                assert secret not in raw_log, "Sensitive request data must not appear in logs"
            assert all(r.get("path") != "/health" for r in records)
            print("PASS: startup route, per-request accounts/proxies, failures, request IDs, durations, credential/body/query exclusion")
            print("PASS: loopback listener, bearer validation, account mismatch, CONNECT routing, auth/YAML reload, unmapped account, invalid YAML, unavailable proxy without cross-proxy fallback")
    finally:
        if process:
            process.terminate()
            try:
                process.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.communicate()
                raise AssertionError("SIGTERM did not stop server")
        for probe in probes:
            probe.shutdown()
            probe.server_close()

if __name__ == "__main__":
    main()
