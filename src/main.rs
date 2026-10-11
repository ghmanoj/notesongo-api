use axum::{
    Json, Router,
    body::Bytes,
    extract::{DefaultBodyLimit, Request, State},
    http::{HeaderMap, header},
    middleware::{self, Next},
    response::Response,
    routing::post,
};
use chrono::Utc;
use fantoccini::{Client, ClientBuilder, Locator};
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::{env, sync::Arc, time::Duration};
use tokio::{
    process::Command,
    sync::Mutex,
    time::{Instant, timeout},
};

const HELP: &str = "help:command, utility:logout, utility:lock, utility:mailbox, system:status";
const LOGIN: &str =
    "https://reg.usps.com/entreg/LoginAction_input?app=Phoenix&appURL=https://www.usps.com/";
const DASHBOARD: &str =
    "https://informeddelivery.usps.com/box/pages/secure/DashboardAction_input.action?restart=1";

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Message {
    command: String,
    modifier: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
struct Reply {
    #[serde(rename = "type")]
    kind: String,
    message: String,
    status: bool,
}
impl Reply {
    fn new(kind: &str, message: impl Into<String>, status: bool) -> Self {
        Self {
            kind: kind.into(),
            message: message.into(),
            status,
        }
    }
    fn invalid() -> Self {
        Self::new("Unknown", "Invalid command message", false)
    }
}

struct Cache {
    day: String,
    reply: Reply,
    retry_after: Instant,
}
#[derive(Default)]
struct AppState {
    mailbox: Mutex<Option<Cache>>,
}

fn router(state: Arc<AppState>) -> Router {
    Router::new()
        .route("/utilities_local", post(handle))
        .layer(DefaultBodyLimit::max(100 * 1024))
        .layer(middleware::from_fn(log_request))
        .with_state(state)
}

async fn log_request(request: Request, next: Next) -> Response {
    let method = request.method().clone();
    let path = request.uri().path().to_owned();
    let started = Instant::now();
    let response = next.run(request).await;
    tracing::info!(
        target: "notesongo_api::requests",
        method = %method,
        path = ?path,
        status = response.status().as_u16(),
        duration_ms = started.elapsed().as_secs_f64() * 1000.0,
        "API request completed"
    );
    response
}

async fn handle(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    body: Bytes,
) -> Json<Reply> {
    let content_type = headers
        .get(header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("")
        .split(';')
        .next()
        .unwrap_or("")
        .trim();
    let message: Result<Message, ()> = match content_type {
        "application/json" => serde_json::from_slice(&body).map_err(|_| ()),
        "application/x-www-form-urlencoded" => serde_urlencoded::from_bytes(&body).map_err(|_| ()),
        _ => Err(()),
    };
    let Ok(message) = message else {
        return Json(Reply::invalid());
    };
    Json(
        match (message.command.as_str(), message.modifier.as_str()) {
            ("help", "command") => Reply::new("help", HELP, true),
            ("system", "status") => execute("uptime", "uptime", &[]).await,
            // Preserve the existing command mapping, including lock's logout behavior.
            ("utility", "logout" | "lock") => execute("shutdown /l", "shutdown", &["/l"]).await,
            ("utility", "mailbox") => mailbox(&state).await,
            _ => Reply::invalid(),
        },
    )
}

async fn execute(kind: &str, program: &str, args: &[&str]) -> Reply {
    let mut command = Command::new(program);
    command.args(args).kill_on_drop(true);
    match timeout(Duration::from_secs(10), command.output()).await {
        Err(_) => Reply::new(kind, "Command timed out", false),
        Ok(Err(error)) => Reply::new(kind, error.to_string(), false),
        Ok(Ok(output)) => {
            let stderr = String::from_utf8_lossy(&output.stderr);
            if !output.status.success() {
                Reply::new(
                    kind,
                    format!("Command failed ({}): {}", output.status, stderr.trim()),
                    false,
                )
            } else if !stderr.is_empty() {
                Reply::new(kind, stderr.into_owned(), false)
            } else {
                Reply::new(kind, String::from_utf8_lossy(&output.stdout).trim(), true)
            }
        }
    }
}

async fn mailbox(state: &AppState) -> Reply {
    // Only mailbox callers wait on this lock; all other routes remain responsive.
    let mut cache = state.mailbox.lock().await;
    let today = Utc::now().format("%Y-%m-%d").to_string();
    if let Some(entry) = cache.as_ref()
        && entry.day == today
        && (entry.reply.status || Instant::now() < entry.retry_after)
    {
        return entry.reply.clone();
    }
    let reply = match (env::var("USPS_USR"), env::var("USPS_PW")) {
        (Ok(user), Ok(password)) if !user.is_empty() && !password.is_empty() => {
            match fetch_mailbox(&user, &password).await {
                Ok(items) => parse_mailbox(&items),
                Err(error) => {
                    // Do not log browser errors: they can include credentials or page content.
                    tracing::warn!("USPS fetch failed: {error}");
                    Reply::new("mailbox", "Error while fetching data from USPS", false)
                }
            }
        }
        _ => Reply::new("mailbox", "Something is not right", false),
    };
    *cache = Some(Cache {
        day: today,
        reply: reply.clone(),
        retry_after: Instant::now() + Duration::from_secs(30),
    });
    reply
}

fn parse_mailbox(items: &[String]) -> Reply {
    let count = items
        .iter()
        .filter(|s| s.trim().starts_with("Today"))
        .find_map(|s| {
            s.split('(').skip(1).find_map(|part| {
                let digits = part.split_once(')')?.0;
                if digits.is_empty() || !digits.bytes().all(|b| b.is_ascii_digit()) {
                    return None;
                }
                digits.parse::<u64>().ok()
            })
        });
    match count {
        Some(0) => Reply::new("mailbox", "No Mails", true),
        Some(1) => Reply::new("mailbox", "You have 1 mail", true),
        Some(n) => Reply::new("mailbox", format!("You have {n} mails"), true),
        None => Reply::new("mailbox", "Nothing.", false),
    }
}

async fn fetch_mailbox(user: &str, password: &str) -> Result<Vec<String>, &'static str> {
    let webdriver = env::var("WEBDRIVER_URL").unwrap_or_else(|_| "http://127.0.0.1:9515".into());
    fetch_mailbox_from(
        &webdriver,
        env::var("BROWSER_PATH").ok().as_deref(),
        user,
        password,
    )
    .await
}

async fn fetch_mailbox_from(
    webdriver: &str,
    browser: Option<&str>,
    user: &str,
    password: &str,
) -> Result<Vec<String>, &'static str> {
    let mut options = json!({"args": ["--headless=new"]});
    if let Some(path) = browser {
        options["binary"] = json!(path);
    }
    let capabilities = json!({"goog:chromeOptions": options})
        .as_object()
        .unwrap()
        .clone();
    let client = timeout(Duration::from_secs(20), async {
        ClientBuilder::rustls()
            .map_err(|_| "TLS initialization failed")?
            .capabilities(capabilities)
            .connect(webdriver)
            .await
            .map_err(|_| "Browser connection failed")
    })
    .await
    .map_err(|_| "Browser connection timed out")??;
    let result = timeout(Duration::from_secs(90), scrape(&client, user, password)).await;
    // Always attempt session cleanup, including after a scrape error or timeout.
    let _ = timeout(Duration::from_secs(10), client.close()).await;
    result
        .map_err(|_| "USPS timed out")?
        .map_err(|_| "USPS browser operation failed")
}

async fn scrape(
    client: &Client,
    user: &str,
    password: &str,
) -> Result<Vec<String>, fantoccini::error::CmdError> {
    client.goto(LOGIN).await?;
    client
        .wait()
        .for_element(Locator::Css("#username"))
        .await?
        .send_keys(user)
        .await?;
    client
        .find(Locator::Css("#password"))
        .await?
        .send_keys(password)
        .await?;
    client
        .find(Locator::Css("#btn-submit"))
        .await?
        .click()
        .await?;
    // Wait for login navigation before opening the authenticated dashboard.
    while client.current_url().await?.host_str() == Some("reg.usps.com") {
        tokio::time::sleep(Duration::from_millis(200)).await;
    }
    client.goto(DASHBOARD).await?;
    client
        .wait()
        .for_element(Locator::Css("#cp_week li"))
        .await?;
    let value = client.execute("return Array.from(document.querySelectorAll('#cp_week li'), e => e.textContent.trim());", vec![]).await?;
    Ok(value
        .as_array()
        .map(|a| {
            a.iter()
                .filter_map(|v| v.as_str().map(String::from))
                .collect()
        })
        .unwrap_or_default())
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    dotenvy::dotenv().ok();
    tracing_subscriber::fmt()
        .with_env_filter(env::var("RUST_LOG").unwrap_or_else(|_| "info".into()))
        .init();
    let address = env::var("BIND_ADDR").unwrap_or_else(|_| "0.0.0.0:8081".into());
    let listener = tokio::net::TcpListener::bind(&address).await?;
    tracing::info!("Listening on {}", listener.local_addr()?);
    axum::serve(listener, router(Arc::new(AppState::default())))
        .with_graceful_shutdown(async {
            let _ = tokio::signal::ctrl_c().await;
        })
        .await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::{
        body::{Body, to_bytes},
        http::Request,
    };
    use tower::ServiceExt;

    #[tokio::test]
    async fn browser_protocol_and_cleanup_on_success_and_failure() {
        use axum::{
            extract::Request,
            http::{Method, StatusCode},
            response::IntoResponse,
        };
        use std::sync::atomic::{AtomicUsize, Ordering};
        #[derive(Default)]
        struct Driver {
            closes: AtomicUsize,
            fail: bool,
        }
        async fn mock(State(driver): State<Arc<Driver>>, req: Request) -> axum::response::Response {
            let method = req.method().clone();
            let path = req.uri().path().to_owned();
            let body = to_bytes(req.into_body(), 65536).await.unwrap();
            let value = if path == "/session" {
                let caps: serde_json::Value = serde_json::from_slice(&body).unwrap();
                assert!(caps.to_string().contains("--headless=new"));
                json!({"sessionId":"test", "capabilities": {"browserName":"chrome"}})
            } else if method == Method::DELETE {
                driver.closes.fetch_add(1, Ordering::SeqCst);
                json!(null)
            } else if path.ends_with("/url") && method == Method::GET {
                json!("https://www.usps.com/")
            } else if path.ends_with("/element") {
                json!({"element-6066-11e4-a52e-4f735466cecf":"element"})
            } else if path.ends_with("/execute/sync") {
                if driver.fail {
                    return (
                        StatusCode::INTERNAL_SERVER_ERROR,
                        Json(json!({"value": {
                        "error":"javascript error", "message":"mock failure", "stacktrace":""}})),
                    )
                        .into_response();
                }
                json!(["Today Mail(3)", "Yesterday Mail(1)"])
            } else {
                json!(null)
            };
            Json(json!({"value": value})).into_response()
        }
        for fail in [false, true] {
            let driver = Arc::new(Driver {
                fail,
                ..Default::default()
            });
            let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
            let address = listener.local_addr().unwrap();
            let app = Router::new().fallback(mock).with_state(driver.clone());
            let task = tokio::spawn(async move {
                axum::serve(listener, app).await.unwrap();
            });
            let result = fetch_mailbox_from(
                &format!("http://{address}"),
                None,
                "test-user",
                "test-password",
            )
            .await;
            if fail {
                assert!(result.is_err());
            } else {
                assert_eq!(result.unwrap(), vec!["Today Mail(3)", "Yesterday Mail(1)"]);
            }
            assert_eq!(driver.closes.load(Ordering::SeqCst), 1);
            task.abort();
        }
    }

    #[tokio::test]
    async fn rejects_oversized_body_and_wrong_method() {
        let app = router(Arc::new(AppState::default()));
        let response = app
            .clone()
            .oneshot(
                Request::post("/utilities_local")
                    .header("content-type", "application/json")
                    .body(Body::from("x".repeat(100 * 1024 + 1)))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), 413);
        let response = app
            .oneshot(
                Request::get("/utilities_local")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), 405);
    }

    async fn request(content_type: &str, body: &str) -> Reply {
        let response = router(Arc::new(AppState::default()))
            .oneshot(
                Request::post("/utilities_local")
                    .header("content-type", content_type)
                    .body(Body::from(body.to_owned()))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), 200);
        assert_eq!(response.headers()["content-type"], "application/json");
        serde_json::from_slice(&to_bytes(response.into_body(), 1024 * 1024).await.unwrap()).unwrap()
    }

    #[tokio::test]
    async fn rejects_invalid_requests_without_executing_commands() {
        for body in [
            "{}",
            "null",
            "[]",
            "{",
            r#"{"command":"system","modifier":"status","extra":1}"#,
            r#"{"command":"system","modifier":1}"#,
            r#"{"command":"system; echo hacked","modifier":"status"}"#,
        ] {
            assert_eq!(request("application/json", body).await, Reply::invalid());
        }
        assert_eq!(request("text/plain", "anything").await, Reply::invalid());
    }

    #[tokio::test]
    async fn accepts_ios_json_and_legacy_form() {
        for (content_type, body) in [
            (
                "application/json; charset=utf-8",
                r#"{"command":"help","modifier":"command"}"#,
            ),
            (
                "application/x-www-form-urlencoded",
                "command=help&modifier=command",
            ),
        ] {
            assert_eq!(
                request(content_type, body).await,
                Reply::new("help", HELP, true)
            );
        }
    }

    #[test]
    fn mailbox_counts_and_missing_data() {
        for (input, message) in [
            ("Today Mail(0)", "No Mails"),
            ("Today Mail(1)", "You have 1 mail"),
            ("Today Mail(42)", "You have 42 mails"),
        ] {
            assert_eq!(
                parse_mailbox(&[input.into()]),
                Reply::new("mailbox", message, true)
            );
        }
        for items in [
            vec![],
            vec!["Yesterday Mail(2)".into()],
            vec!["Today Mail(x)".into()],
        ] {
            assert_eq!(
                parse_mailbox(&items),
                Reply::new("mailbox", "Nothing.", false)
            );
        }
    }

    #[tokio::test]
    async fn concurrent_mailbox_requests_use_cache() {
        let reply = Reply::new("mailbox", "You have 2 mails", true);
        let state = AppState {
            mailbox: Mutex::new(Some(Cache {
                day: Utc::now().format("%Y-%m-%d").to_string(),
                reply: reply.clone(),
                retry_after: Instant::now(),
            })),
        };
        let (a, b) = tokio::join!(mailbox(&state), mailbox(&state));
        assert_eq!(a, reply);
        assert_eq!(b, reply);
    }

    #[tokio::test]
    async fn process_success_and_failure() {
        assert_eq!(
            execute("test", "/bin/echo", &["hello"]).await,
            Reply::new("test", "hello", true)
        );
        assert!(!execute("test", "/bin/false", &[]).await.status);
        assert!(
            !execute("test", "/nonexistent/notesongo-api", &[])
                .await
                .status
        );
    }
}
