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
    amerilingua = False
    expired_pdf = False

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
        if self.amerilingua and self.path == "/login":
            self.reply(200, b"<form><input type='hidden' name='_token' value='fresh&amp;=token'></form>",
                       Set_Cookie="preauth=fresh; Path=/; HttpOnly")
        elif self.path.startswith("/esl-lesson-plans"):
            fixture = "index.html" if self.path in ("/esl-lesson-plans", "/esl-lesson-plans?page=2") else "lesson.html"
            body = (ROOT / "test/fixtures/amerilingua" / fixture).read_text()
            if self.path.endswith("page=2") or self.path.endswith("lesson-two"):
                body = body.replace("lesson-one", "lesson-two").replace('<a href="?page=2" rel="next">»</a>', "")
            if fixture == "lesson.html" and "laravel_session=valid" not in self.headers.get("Cookie", ""):
                body = '<div class="lesson-files"><div class="lesson-files-item"><a href="#">Log in</a></div></div>'
            self.reply(200, body.encode())
        elif self.path.startswith("/lesson-file/"):
            body = b"<html>Log in</html>" if self.expired_pdf else b"%PDF-1.4\nSynthetic fixture\n%%EOF\n"
            self.reply(200, body, Content_Length=str(len(body)))
        elif self.path == "/external":
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
        if self.amerilingua and self.path == "/login":
            expected = {"_token": ["fresh&=token"], "email": ["demo+test@example.invalid"], "password": ["demo&=+ secret"]}
            if parse_qs(body) == expected and "preauth=fresh" in self.headers.get("Cookie", ""):
                self.reply(302, Location="/esl-lesson-plans", Set_Cookie="laravel_session=valid; Path=/; HttpOnly")
            else:
                self.reply(401)
        elif self.path == "/login" and parse_qs(body) == {"name": ["test+&=é"], "password": ["p&=+ss"]}:
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
        test_amerilingua(executable, origin, Path(temporary))
    print("CLI, failure recovery, HTTP errors, streaming, login, AmeriLingua and resume passed.")


def test_amerilingua(executable, origin, temporary):
    """Fresh CSRF + cookies, pagination, all PDFs, and expired sessions returning HTML."""
    Handler.amerilingua = True
    env = {**os.environ, "AMERILINGUA_LOGIN": "demo+test@example.invalid", "AMERILINGUA_PASS": "demo&=+ secret"}
    output = temporary / "amerilingua"
    command = [executable, "amerilingua", "--base-url", origin + "esl-lesson-plans", "--output", str(output),
               "--delay-ms", "0", "--retries", "0"]
    denied = check(command, env={**env, "AMERILINGUA_PASS": "wrong-secret"}, success=False)
    assert "wrong-secret" not in denied.stdout + denied.stderr
    check(command, env=env)
    assert len(list(output.glob("*/*.pdf"))) == 10, "Did not download every PDF on both catalogue pages"
    assert "#slide=id.demo" in (output / "lesson-one/links.txt").read_text()
    requests = Handler.requests.copy()
    check(command, env=env)
    assert all(Handler.requests[path] == count for path, count in requests.items()
               if path.startswith("/lesson-file/")), "Resume downloaded completed lesson files"
    single = temporary / "amerilingua-single"
    single_command = [executable, "amerilingua", "--base-url", origin + "esl-lesson-plans/lesson-one",
                      "--output", str(single), "--delay-ms", "0", "--retries", "0"]
    Handler.expired_pdf = True
    check(single_command, env=env, success=False)
    assert not list(single.glob("*.pdf")) and not (single / ".scraper-finished").exists()
    assert not (single / ".scraper-urls").exists(), "HTML response entered the download cache"
    Handler.expired_pdf = False
    check(single_command, env=env)
    assert len(list(single.glob("*.pdf"))) == 5


if __name__ == "__main__":
    main()
