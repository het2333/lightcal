#!/usr/bin/env python3
"""Forward local API traffic while dropping the first hydration response."""

from __future__ import annotations

import argparse
import socket
import threading
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


HOP_BY_HOP_HEADERS = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailers",
    "transfer-encoding",
    "upgrade",
}


class ResponseLossState:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._hydration_response_dropped = False

    def should_drop_hydration_response(self) -> bool:
        with self._lock:
            if self._hydration_response_dropped:
                return False
            self._hydration_response_dropped = True
            return True


def make_handler(upstream: str, state: ResponseLossState):
    class ResponseLossProxyHandler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def do_GET(self) -> None:  # noqa: N802
            self._forward()

        def do_POST(self) -> None:  # noqa: N802
            self._forward()

        def do_PUT(self) -> None:  # noqa: N802
            self._forward()

        def do_DELETE(self) -> None:  # noqa: N802
            self._forward()

        def _forward(self) -> None:
            body_length = int(self.headers.get("Content-Length", "0") or 0)
            body = self.rfile.read(body_length) if body_length else None
            headers = {
                key: value
                for key, value in self.headers.items()
                if key.lower() not in HOP_BY_HOP_HEADERS
                and key.lower() not in {"host", "accept-encoding", "content-length"}
            }
            request = urllib.request.Request(
                upstream + self.path,
                data=body,
                headers=headers,
                method=self.command,
            )
            try:
                with urllib.request.urlopen(request, timeout=60) as response:
                    status = response.status
                    response_headers = response.headers
                    response_body = response.read()
            except urllib.error.HTTPError as error:
                status = error.code
                response_headers = error.headers
                response_body = error.read()

            is_first_hydration_post = (
                self.command == "POST"
                and self.path.split("?", 1)[0].rstrip("/") == "/v6/hydration"
                and state.should_drop_hydration_response()
            )
            if is_first_hydration_post:
                print("Dropped first hydration response after upstream saved it", flush=True)
                self.close_connection = True
                try:
                    self.connection.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
                self.connection.close()
                return

            self.send_response(status)
            for key, value in response_headers.items():
                if key.lower() not in HOP_BY_HOP_HEADERS and key.lower() != "content-length":
                    self.send_header(key, value)
            self.send_header("Content-Length", str(len(response_body)))
            self.end_headers()
            self.wfile.write(response_body)

        def log_message(self, format: str, *args: object) -> None:
            print(f"{self.command} {self.path}: {format % args}", flush=True)

    return ResponseLossProxyHandler


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--listen-host", default="127.0.0.1")
    parser.add_argument("--listen-port", type=int, default=8013)
    parser.add_argument("--upstream", default="http://127.0.0.1:8012")
    args = parser.parse_args()

    state = ResponseLossState()
    handler = make_handler(args.upstream.rstrip("/"), state)
    server = ThreadingHTTPServer((args.listen_host, args.listen_port), handler)
    print(
        f"Response-loss proxy listening on http://{args.listen_host}:{args.listen_port} "
        f"-> {args.upstream}",
        flush=True,
    )
    server.serve_forever()


if __name__ == "__main__":
    main()
