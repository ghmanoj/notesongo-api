# notesongo-api

Zig backend for NotesOnGo. The iOS app needs no changes: the default address is
`0.0.0.0:8081`, the endpoint is `POST /utilities_local`, and responses contain
`type` (string), `message` (string), and `status` (boolean).

## Run

Use **Zig 0.17.0**, then run from this directory:

```sh
cp .env.example .env
zig build -Doptimize=ReleaseFast
./zig-out/bin/notesongo-api
```

For development, use `zig build run`. There are no third-party Zig packages.
The executable links libc and currently supports macOS and Linux. ChromeDriver
is needed only for mailbox requests. Python 3 is needed only for the verification
and benchmark scripts. Rust, Cargo, Node.js, and Puppeteer are not required.

Configuration is loaded from `.env` without overriding existing environment
variables. Basic `KEY=value`, quoted values, `export`, and comment lines are
supported; shell interpolation and multiline values are not supported.

| Variable | Default | Purpose |
| --- | --- | --- |
| `BIND_ADDR` | `0.0.0.0:8081` | IPv4 address:port or [IPv6 address]:port |
| `USPS_USR` / `USPS_PW` | unset | USPS login credentials |
| `WEBDRIVER_URL` | `http://127.0.0.1:9515` | Running ChromeDriver service |
| `BROWSER_PATH` | browser chosen by ChromeDriver | Chrome/Chromium/Brave executable |
| `LOG_LEVEL` | `info` | `off`, `error`, `warn`, `info`, or `debug` |

`RUST_LOG` is accepted as a legacy fallback when `LOG_LEVEL` is unset.
`notesongo_api::requests=off` in the legacy value disables request logs.

## API

```sh
curl http://localhost:8081/utilities_local \
  -H 'Content-Type: application/json' \
  -d '{"command":"system","modifier":"status"}'
```

JSON and URL-encoded forms accept exactly two string fields: `command` and
`modifier`. Invalid requests return the existing `Unknown` error envelope with
HTTP 200; bodies larger than 100 KiB return HTTP 413. Unknown routes return 404,
and unsupported methods return 405. Persistent HTTP connections are supported.

| Command | Modifier | Response type / behavior |
| --- | --- | --- |
| `system` | `status` | `uptime`; runs the host's `uptime` executable |
| `utility` | `logout` | `shutdown /l`; runs `shutdown` with `/l` |
| `utility` | `lock` | Same legacy mapping as logout |
| `utility` | `mailbox` | `mailbox`; today's USPS mail count |
| `help` | `command` | `help`; lists supported commands |

Logout and lock preserve the original Windows command mapping. On macOS/Linux,
`shutdown /l` generally fails. Commands run without a shell, with a 10 second
limit and bounded output. Timed-out or cancelled child processes are killed.
Command failures keep HTTP 200 and set the JSON `status` to false. Operating-system
error messages can differ from the former Rust backend.

Connections run concurrently; mailbox callers share a mutex while help and
process commands remain responsive. SIGINT and SIGTERM stop acceptance, cancel
active work, kill command children, and attempt browser session cleanup.

Completed requests are logged to stdout with a Unix timestamp, method, escaped path,
HTTP status, and duration in milliseconds. Bodies, headers, query strings,
and response data are excluded. The service retains its unauthenticated API;
deploy on a trusted private network.

## Mailbox browser setup

Install ChromeDriver compatible with your Chrome/Chromium/Brave version and
start it separately:

```sh
chromedriver --port=9515
curl --fail http://127.0.0.1:9515/status
```

For Brave on macOS, set:

```dotenv
BROWSER_PATH="/Applications/Brave Browser.app/Contents/MacOS/Brave Browser"
```

The Zig client speaks the W3C WebDriver protocol directly. It creates a headless
browser session, logs into USPS, reads `#cp_week li`, and attempts to close the
session on success, failure, timeout, and shutdown. Connection, scraping, and
cleanup have separate 20/90/10 second limits. An unresponsive driver can leave an
orphaned session; supervise the driver in deployment.

Successful results are cached until the UTC date changes. Failures are cached
for 30 seconds, and concurrent callers share one fetch. Missing credentials
return `Something is not right` without preventing startup. Zero and one mail
return `No Mails` and `You have 1 mail` respectively.

Restart after changing `.env`. If the driver is unreachable, check its host and
port. If it cannot create a session, check browser/driver version compatibility,
`BROWSER_PATH`, and ChromeDriver's terminal output. The API logs only safe error
names rather than driver response bodies. USPS login changes, CAPTCHA, or MFA
may prevent automated access. Real USPS login must be verified with your account.

## Verify and measure

```sh
zig fmt --check build.zig src/main.zig
zig build test
zig build -Doptimize=ReleaseFast
python3 scripts/integration_test.py
python3 scripts/benchmark.py --requests 10000 --concurrency 32
```

The integration script starts isolated API processes and a mock ChromeDriver.
It verifies request validation, routing, size limits, persistent connections,
concurrency, mailbox caching, browser cleanup on success/failure, secret-free
logs, and shutdown during an active fetch. It does not contact USPS or execute
logout/shutdown commands on your host.

Run the benchmark against a separately running release binary. It validates
all help responses and reports throughput and latency. Compare the same workload
on the same machine; historical Rust results do not establish Zig performance.

The obsolete `Cargo.lock` is retained to preserve a pre-existing local edit.
It is not used by the Zig build and can be removed when that edit is no longer
needed.
