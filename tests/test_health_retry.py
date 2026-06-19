#!/usr/bin/env python3
"""Tests for health check retry/backoff behavior."""
import json
import os
import socket
import subprocess
import sys
import time
import threading
import http.server

TOOLS_DIR = os.path.join(os.path.dirname(__file__), "..", "tools")
sys.path.insert(0, TOOLS_DIR)

from health_check import check_http_service, check_tcp_port

def test_http_success_no_retry():
    handler = http.server.BaseHTTPRequestHandler
    handler.do_GET = lambda self: (self.send_response(200), self.end_headers(), self.wfile.write(b"ok"))
    server = http.server.HTTPServer(("127.0.0.1", 18345), handler)
    t = threading.Thread(target=server.handle_request, daemon=True)
    t.start()
    time.sleep(0.1)
    status, detail, code = check_http_service("127.0.0.1", 18345, "/health", 5)
    assert status == "OK", f"expected OK, got {status}: {detail}"
    assert code == 200
    server.server_close()

def test_http_retries_on_refused():
    start = time.time()
    status, detail, code = check_http_service("127.0.0.1", 1, "/health", 2, retries=2, backoff=0.01)
    elapsed = time.time() - start
    assert status == "CRITICAL", f"expected CRITICAL, got {status}"
    assert "after 3 attempts" in detail, f"expected retry count: {detail}"
    assert elapsed >= 0.01

def test_http_no_retry_default():
    status, detail, code = check_http_service("127.0.0.1", 1, "/health", 2)
    assert status == "CRITICAL"
    assert "after" not in detail

def test_tcp_success_no_retry():
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.bind(("127.0.0.1", 18346))
    server.listen(1)
    status, detail, latency = check_tcp_port("127.0.0.1", 18346, 5)
    assert status == "OK", f"expected OK, got {status}: {detail}"
    assert latency > 0
    server.close()

def test_tcp_retries_on_refused():
    start = time.time()
    status, detail, latency = check_tcp_port("127.0.0.1", 1, 2, retries=2, backoff=0.01)
    elapsed = time.time() - start
    assert status == "CRITICAL"
    assert "after 3 attempts" in detail
    assert elapsed >= 0.01

def test_tcp_no_retry_default():
    status, detail, latency = check_tcp_port("127.0.0.1", 1, 2)
    assert status == "CRITICAL"
    assert "after" not in detail

def test_cli_flags_exist():
    result = subprocess.run(
        [sys.executable, os.path.join(TOOLS_DIR, "health_check.py"), "--help"],
        capture_output=True, text=True
    )
    assert "--retries" in result.stdout
    assert "--backoff" in result.stdout

def test_json_includes_retry_config():
    result = subprocess.run(
        [sys.executable, os.path.join(TOOLS_DIR, "health_check.py"), "--json", "--retries", "1", "--backoff", "0.1"],
        capture_output=True, text=True, timeout=30
    )
    data = json.loads(result.stdout)
    assert "retry_config" in data
    assert data["retry_config"]["retries"] == 1
    assert data["retry_config"]["backoff"] == 0.1

def test_tcp_success_after_retry():
    port = 18347
    def delayed_server():
        time.sleep(0.2)
        server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server.bind(("127.0.0.1", port))
        server.listen(1)
        conn, _ = server.accept()
        conn.close()
        server.close()
    t = threading.Thread(target=delayed_server, daemon=True)
    t.start()
    status, detail, latency = check_tcp_port("127.0.0.1", port, 5, retries=5, backoff=0.1)
    assert status == "OK", f"expected OK after retry, got {status}: {detail}"

if __name__ == "__main__":
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    passed = 0
    failed = 0
    for test in tests:
        try:
            test()
            print(f"  PASS: {test.__name__}")
            passed += 1
        except Exception as e:
            print(f"  FAIL: {test.__name__}: {e}")
            failed += 1
    print(f"\n{passed} passed, {failed} failed")
    sys.exit(1 if failed else 0)
