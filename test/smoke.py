"""Exercise the built CLI and HTTP regressions on loopback, using only stdlib."""

from collections import Counter
from contextlib import contextmanager
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from tempfile import TemporaryDirectory
from threading import Thread
from urllib.parse import parse_qs
import os
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]


class Handler(SimpleHTTPRequestHandler):
    requests = Counter()
    fail_poem = False

    def log_message(self, *_):
        pass

    def reply(self, status, body=b"", **headers):
        self.send_response(status)
        for key, value in headers.items():
            self.send_header(key.replace("_", "-"), value)
        self.end_headers()
        try:
            self.wfile.write(body)
        except BrokenPipeError:
            pass  # Expected when testing the client's timeout.

    def do_GET(self):
        self.requests[self.path] += 1
        if self.path == "/external":
            self.reply(302, Location=f"http://localhost:{self.server.server_port}/asset")
        elif self.path == "/slow":
            time.sleep(1.5)
            self.reply(200, b"late")
        elif self.path == "/broken":
            self.reply(200, b"incomplete", Content_Length="100000")
        elif self.path == "/asset":
            self.reply(200, b"x" * 100000)
        elif self.path == "/protected":
            self.reply(200, b"authenticated") if self.headers.get("Cookie") == "session=valid" else self.reply(401)
        elif self.path == "/p_demo.html" and self.fail_poem:
            self.reply(503)
        else:
            super().do_GET()

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0))).decode()
        if self.path == "/login" and parse_qs(body) == {"name": ["test+&=é"], "password": ["p&=+ss"]}:
            self.reply(302, Location="/protected", Set_Cookie="session=valid; Path=/")
        else:
            self.reply(401)


@contextmanager
def server():
    with ThreadingHTTPServer(("127.0.0.1", 0), partial(Handler, directory=str(ROOT / "test/fixtures"))) as httpd:
        thread = Thread(target=httpd.serve_forever, daemon=True)
        thread.start()
        try:
            yield f"http://127.0.0.1:{httpd.server_port}/"
        finally:
            httpd.shutdown()
            thread.join()


def check(command, success=True, **kwargs):
    result = subprocess.run(command, capture_output=True, text=True, cwd=ROOT, **kwargs)
    assert (result.returncode == 0) == success, (command, result.stdout, result.stderr)
    return result


def main():
    executable = os.environ.get("SCRAPER_EXE") or str(
        Path(check(["stack", "path", "--local-install-root"]).stdout.strip()) / "bin/haskellwebscrapper-exe"
    )
    check([executable, "--help"])
    check([executable, "hafez", "--retries", "bad"], success=False)
    with server() as origin, TemporaryDirectory(prefix="scraper-smoke-") as temporary:
        output = Path(temporary) / "downloads"
        command = [executable, "hafez", "--base-url", origin, "--output", str(output), "--delay-ms", "0", "--retries", "0"]
        Handler.fail_poem = True
        check(command, success=False)
        assert not (output / ".scraper-finished").exists()
        Handler.fail_poem = False
        check(command)
        poem = output / "index-01.html/p_demo.html"
        assert (poem / "en.txt").read_text() == "Hello world.\nOne & two.\n\nAnother line.\n"
        assert (poem / "fa.txt").read_text(encoding="utf-8").startswith("سلام دنیا")
        requests = Handler.requests.copy()
        check(command)
        assert Handler.requests == requests, "Completed crawl made additional requests"
        assert not (output / ".scraper-lock").exists()
        tests = [os.environ["SCRAPER_TEST_EXE"]] if "SCRAPER_TEST_EXE" in os.environ else ["stack", "test"]
        check(tests, env={**os.environ, "SCRAPER_TEST_ORIGIN": origin})
        assert Handler.requests["/asset"] == 1, "Cached asset was fetched twice"
    print("CLI, failure recovery, HTTP errors, streaming, login and resume passed.")


if __name__ == "__main__":
    main()
