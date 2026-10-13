"""Exercise the compiled Zig API and a local W3C WebDriver mock (stdlib only)."""
import concurrent.futures
import http.client
import http.server
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
BINARY = ROOT / 'zig-out/bin/notesongo-api'
INVALID = {'type': 'Unknown', 'message': 'Invalid command message', 'status': False}


class API:
    def __init__(self, dotenv=None, **env):
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            self.port = sock.getsockname()[1]
        # An empty cwd prevents a developer's .env from entering the tests.
        self.directory = tempfile.TemporaryDirectory()
        if dotenv is not None:
            Path(self.directory.name, '.env').write_text(dotenv)
        self.log = tempfile.TemporaryFile(mode='w+b')
        self.process = subprocess.Popen([str(BINARY)], cwd=self.directory.name,
            env={**{key: value for key, value in os.environ.items() if key != 'LOG_LEVEL'},
                 'RUST_LOG': 'info', 'BIND_ADDR': f'127.0.0.1:{self.port}',
                 'USPS_USR': '', 'USPS_PW': '', **env}, stdout=self.log, stderr=self.log)
        for _ in range(100):
            if self.process.poll() is not None:
                self.log.seek(0)
                raise RuntimeError(self.log.read().decode())
            try:
                with socket.create_connection(('127.0.0.1', self.port), timeout=.1):
                    break
            except OSError:
                time.sleep(.05)
        else:
            self.close()
            raise RuntimeError('API did not start')

    def request(self, body=None, method='POST', path='/utilities_local', content_type='application/json'):
        conn = http.client.HTTPConnection('127.0.0.1', self.port, timeout=15)
        try:
            if isinstance(body, dict):
                body = json.dumps(body)
            conn.request(method, path, body, {'Content-Type': content_type})
            response = conn.getresponse()
            data = response.read()
            return response.status, json.loads(data) if data else None
        finally:
            conn.close()

    def command(self, command, modifier):
        return self.request({'command': command, 'modifier': modifier})

    def close(self):
        self.process.send_signal(signal.SIGINT)
        try:
            code = self.process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()
            raise AssertionError('shutdown timed out')
        finally:
            self.directory.cleanup()
            self.log.close()
        if code != 0:
            raise AssertionError(f'API exited with {code}')


class Driver(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        self.handle_command()

    def do_GET(self):
        self.handle_command()

    def do_DELETE(self):
        self.handle_command()

    def handle_command(self):
        payload = json.loads(self.rfile.read(int(self.headers.get('Content-Length', 0))) or b'null')
        with self.server.lock:
            self.server.calls.append((self.command, self.path, payload))
        status, value = 200, None
        if self.path == '/session':
            caps = payload['capabilities']['alwaysMatch']['goog:chromeOptions']
            assert caps['args'] == ['--headless=new']
            assert caps.get('binary') == '/mock/browser'
            value = {'sessionId': 'test', 'capabilities': {'browserName': 'chrome'}}
        elif self.command == 'DELETE':
            self.server.closes += 1
        elif self.path.endswith('/url') and self.command == 'GET':
            value = 'https://www.usps.com/'
        elif self.path.endswith('/element'):
            value = {'element-6066-11e4-a52e-4f735466cecf': 'element'}
        elif self.path.endswith('/execute/sync'):
            self.server.scraping.set()
            if self.server.mode == 'wait':
                self.server.release.wait(15)
            if self.server.mode == 'fail':
                status, value = 500, {'error': 'javascript error', 'message': 'secret must not be logged'}
            else:
                value = ['Today Mail(3)', 'Yesterday Mail(1)']
        encoded = json.dumps({'value': value}).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(encoded)))
        self.end_headers()
        try:
            self.wfile.write(encoded)
        except (BrokenPipeError, ConnectionResetError):
            pass


def mock_driver(mode):
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Driver)
    server.daemon_threads = True
    server.calls, server.closes, server.mode = [], 0, mode
    server.lock = threading.Lock()
    server.scraping, server.release = threading.Event(), threading.Event()
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


class Integration(unittest.TestCase):
    def test_http_contract(self):
        api = API()
        try:
            for content_type, body in [
                ('application/json; charset=utf-8', '{"command":"help","modifier":"command"}'),
                ('application/x-www-form-urlencoded', 'command=h%65lp&modifier=command')]:
                status, reply = api.request(body, content_type=content_type)
                self.assertEqual(status, 200)
                self.assertEqual(reply['type'], 'help')
                self.assertTrue(reply['status'])
            for body in ['{}', 'null', '[]', '{', '{"command":"help","modifier":1}',
                         '{"command":"help","modifier":"command","extra":1}',
                         '{"command":"system; echo hacked","modifier":"status"}']:
                self.assertEqual(api.request(body), (200, INVALID))
            self.assertEqual(api.request('x', content_type='text/plain'), (200, INVALID))
            self.assertEqual(api.request('x' * (100 * 1024 + 1))[0], 413)
            body = '{"command":"help","modifier":"command"}'
            self.assertTrue(api.request(body.ljust(100 * 1024))[1]['status'])
            chunked = http.client.HTTPConnection('127.0.0.1', api.port)
            chunked.request('POST', '/utilities_local', [b'x' * 65536, b'x' * 65536],
                            {'Content-Type': 'application/json'}, encode_chunked=True)
            response = chunked.getresponse()
            self.assertEqual(response.status, 413)
            response.read()
            chunked.close()
            self.assertTrue(api.request(body, path='/utilities_local?secret-query=value')[1]['status'])
            api.log.seek(0)
            logs = api.log.read().decode()
            self.assertIn('duration_ms=', logs)
            self.assertNotIn('secret-query', logs)
            self.assertEqual(api.request(method='GET')[0], 405)
            self.assertEqual(api.request(method='HEAD')[0], 405)
            self.assertEqual(api.request(path='/missing')[0], 404)
            self.assertTrue(api.command('system', 'status')[1]['status'])
            self.assertEqual(api.command('utility', 'mailbox')[1]['message'], 'Something is not right')
            # Persistent connections and concurrent requests are part of the existing contract.
            conn = http.client.HTTPConnection('127.0.0.1', api.port)
            for _ in range(3):
                conn.request('POST', '/utilities_local', '{"command":"help","modifier":"command"}',
                             {'Content-Type': 'application/json'})
                response = conn.getresponse()
                self.assertTrue(json.loads(response.read())['status'])
            conn.close()
            with concurrent.futures.ThreadPoolExecutor(max_workers=16) as pool:
                replies = list(pool.map(lambda _: api.command('help', 'command'), range(64)))
            self.assertTrue(all(status == 200 and reply['status'] for status, reply in replies))
        finally:
            api.close()

    def test_dotenv_and_log_level(self):
        api = API(dotenv='export LOG_LEVEL="off"\nUSPS_USR=file-user\nUSPS_PW=file-password\n')
        try:
            self.assertTrue(api.command('help', 'command')[1]['status'])
            # Existing environment variables, including empty values, win.
            self.assertEqual(api.command('utility', 'mailbox')[1]['message'], 'Something is not right')
            api.log.seek(0)
            self.assertEqual(api.log.read(), b'')
        finally:
            api.close()

    def test_webdriver_success_failure_and_cache(self):
        for mode in ['success', 'fail']:
            with self.subTest(mode=mode):
                driver = mock_driver(mode)
                api = API(USPS_USR='mock-user', USPS_PW='mock-password', BROWSER_PATH='/mock/browser',
                          WEBDRIVER_URL=f'http://127.0.0.1:{driver.server_port}')
                try:
                    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
                        replies = list(pool.map(lambda _: api.command('utility', 'mailbox'), range(8)))
                    self.assertTrue(all(reply == replies[0] for reply in replies))
                    self.assertEqual(replies[0][1]['status'], mode == 'success')
                    if mode == 'success':
                        self.assertEqual(replies[0][1]['message'], 'You have 3 mails')
                    self.assertEqual(driver.closes, 1)
                    self.assertEqual(sum(path == '/session' for _, path, _ in driver.calls), 1)
                    key_payloads = [payload for _, path, payload in driver.calls if path.endswith('/value')]
                    self.assertEqual(key_payloads, [{'text': 'mock-user'}, {'text': 'mock-password'}])
                    api.log.seek(0)
                    logs = api.log.read().decode()
                    for secret in ['mock-user', 'mock-password', 'secret must not be logged']:
                        self.assertNotIn(secret, logs)
                finally:
                    api.close()
                    driver.shutdown()
                    driver.server_close()

    def test_shutdown_closes_active_browser(self):
        driver = mock_driver('wait')
        api = API(USPS_USR='mock-user', USPS_PW='mock-password', BROWSER_PATH='/mock/browser',
                  WEBDRIVER_URL=f'http://127.0.0.1:{driver.server_port}')
        def mailbox():
            try:
                api.command('utility', 'mailbox')
            except (OSError, http.client.HTTPException):
                pass
        thread = threading.Thread(target=mailbox)
        thread.start()
        try:
            self.assertTrue(driver.scraping.wait(5))
            self.assertTrue(api.command('help', 'command')[1]['status'])
            api.close()
            self.assertEqual(driver.closes, 1)
        finally:
            driver.release.set()
            thread.join(5)
            driver.shutdown()
            driver.server_close()


if __name__ == '__main__':
    unittest.main()
