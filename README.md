# notesongo-api

Rust backend for NotesOnGo, using Axum and Tokio. The iOS app needs no changes:
the default address is `0.0.0.0:8081`, the endpoint is `POST /utilities_local`,
and responses contain `type` (string), `message` (string), and `status` (boolean).

## Run

Install stable Rust, then run from this directory:

```sh
cp .env.example .env
cargo build --release --locked
./target/release/notesongo-api
```

USPS credentials are only required for mailbox requests. Other commands work
without them. Configuration is loaded from `.env` without overriding existing
environment variables.

| Variable | Default | Purpose |
| --- | --- | --- |
| `BIND_ADDR` | `0.0.0.0:8081` | Listen address |
| `USPS_USR` / `USPS_PW` | unset | USPS login credentials |
| `WEBDRIVER_URL` | `http://127.0.0.1:9515` | Running ChromeDriver service |
| `BROWSER_PATH` | browser chosen by ChromeDriver | Chrome/Chromium/Brave executable |
| `RUST_LOG` | `info` | Logging filter |

## Mailbox browser setup

Install ChromeDriver compatible with your Chrome/Chromium/Brave version and
start it separately:

```sh
chromedriver --port=9515
```

For Brave on macOS, set:

```dotenv
BROWSER_PATH="/Applications/Brave Browser.app/Contents/MacOS/Brave Browser"
```

The server creates a headless browser session through WebDriver, logs into USPS,
reads `#cp_week li`, and attempts to close the session on success, failure, or
timeout. Node.js and Puppeteer are no longer needed. USPS login changes,
CAPTCHA, or MFA may prevent automated access.

Successful mailbox responses are cached until the UTC date changes, matching
the old backend's day boundary. Concurrent callers share a single fetch.
Failures are cached for 30 seconds to prevent repeated browser launches.
Browser connection, scraping, and cleanup have separate 20/90/10 second limits.
An unresponsive driver can leave an orphaned session; supervise the driver in
deployment. USPS selectors and real login must be verified with your account.

## API

```sh
curl http://localhost:8081/utilities_local \
  -H 'Content-Type: application/json' \
  -d '{"command":"system","modifier":"status"}'
```

JSON and URL-encoded forms accept exactly two string fields: `command` and
`modifier`. Invalid requests return the existing `Unknown` error envelope with
HTTP 200; bodies larger than 100 KiB return HTTP 413.

| Command | Modifier | Response type / behavior |
| --- | --- | --- |
| `system` | `status` | `uptime`; runs the host's `uptime` executable |
| `utility` | `logout` | `shutdown /l`; runs `shutdown` with `/l` |
| `utility` | `lock` | Same legacy mapping as logout |
| `utility` | `mailbox` | `mailbox`; today's USPS mail count |
| `help` | `command` | `help`; lists supported commands |

Logout and lock preserve the original Windows command mapping. On macOS/Linux,
`shutdown /l` generally fails. Commands run without a shell, with a 10 second
timeout. Child processes are killed if the operation is cancelled. The service
retains the original unauthenticated API; deploy on a trusted private network.

Intentional bug fixes: zero/one mail counts now return `No Mails` / `You have 1
mail`, and help returns a valid response instead of attempting to execute an
object. Missing USPS credentials no longer prevent server startup.

## Verify and measure

```sh
cargo fmt --check
cargo clippy --locked --all-targets -- -D warnings
cargo test --locked
python3 scripts/benchmark.py --requests 10000 --concurrency 32
```

Run the benchmark against the release binary. It measures the inexpensive help
route using persistent HTTP connections and checks every response. Reported
latency and throughput depend on the host and load generator. Compare the same
workload on the same machine when evaluating changes; there is no measured
Node.js baseline in this repository. Asynchronous execution keeps browser and
process waits from blocking other routes; it cannot speed up USPS navigation or
the host's external commands.

Local release validation on October 11, 2026 (macOS arm64, Python 3.9.6 load
generator): 10,000 validated help requests, 32 connections, 1.022 seconds,
9,784 requests/second; p50 2.839 ms, p95 6.425 ms, p99 8.373 ms. This is a
single local measurement, not a Node.js comparison or a production guarantee.
Seven automated tests passed, including mock WebDriver success/failure cleanup;
release HTTP checks covered help, uptime, missing credentials, invalid commands,
URL-encoded forms, and graceful shutdown. Real USPS login was not exercised.


