use super::*;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::sync::{Notify, mpsc};
use tokio_rustls::{TlsAcceptor, rustls};

trait Io: AsyncRead + AsyncWrite + Unpin + Send {}
impl<T: AsyncRead + AsyncWrite + Unpin + Send> Io for T {}
type TestIo = Box<dyn Io>;

struct Fixture {
    addr: std::net::SocketAddr,
    certificate: reqwest::Certificate,
    requests: mpsc::UnboundedReceiver<String>,
    release: Arc<Notify>,
    task: tokio::task::JoinHandle<()>,
}
impl Drop for Fixture {
    fn drop(&mut self) {
        self.task.abort();
    }
}
async fn read_request(io: &mut TestIo) -> std::io::Result<String> {
    let mut data = Vec::new();
    while !data.ends_with(b"\r\n\r\n") {
        data.push(io.read_u8().await?);
        assert!(data.len() < 65536);
    }
    let head = String::from_utf8(data).unwrap();
    let length = head
        .lines()
        .find_map(|line| {
            line.to_ascii_lowercase()
                .strip_prefix("content-length:")
                .and_then(|s| s.trim().parse::<usize>().ok())
        })
        .unwrap_or(0);
    let mut body = vec![0; length];
    io.read_exact(&mut body).await?;
    Ok(head + &String::from_utf8(body).unwrap())
}
async fn fixture(mode: &'static str, response_mode: &'static str) -> Fixture {
    let certified = rcgen::generate_simple_self_signed(vec![
        "upstream.invalid".into(),
        "developers.openai.com".into(),
        "localhost".into(),
    ])
    .unwrap();
    let cert = certified.cert.der().clone();
    let certificate = reqwest::Certificate::from_der(cert.as_ref()).unwrap();
    let key = rustls::pki_types::PrivatePkcs8KeyDer::from(certified.signing_key.serialize_der());
    let tls = rustls::ServerConfig::builder()
        .with_no_client_auth()
        .with_single_cert(vec![cert], key.into())
        .unwrap();
    let acceptor = TlsAcceptor::from(Arc::new(tls));
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let (tx, requests) = mpsc::unbounded_channel();
    let release = Arc::new(Notify::new());
    let ready = release.clone();
    let task = tokio::spawn(async move {
        let mut children = tokio::task::JoinSet::new();
        loop {
            let (socket, _) = listener.accept().await.unwrap();
            let acceptor = acceptor.clone();
            let tx = tx.clone();
            let ready = ready.clone();
            children.spawn(async move {
                let mut io:TestIo=Box::new(socket);
                if mode=="https" { io=Box::new(acceptor.accept(io).await.unwrap()); }
                if mode!="direct" {
                    let connect=read_request(&mut io).await.unwrap(); assert!(connect.starts_with("CONNECT ")); assert!(!connect.contains("model-secret"));
                    tx.send(connect).unwrap();
                    io.write_all(b"HTTP/1.1 200 Connection Established\r\n\r\n").await.unwrap();
                }
                let Ok(tls)=acceptor.accept(io).await else { return; }; let mut io:TestIo=Box::new(tls);
                let request=read_request(&mut io).await.unwrap(); let head=request.starts_with("HEAD "); tx.send(request).unwrap();
                if head { io.write_all(b"HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n").await.unwrap(); }
                else if response_mode=="redirect" { io.write_all(b"HTTP/1.1 302 Found\r\nLocation: https://evil.invalid/leak\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").await.unwrap(); }
                else {
                    io.write_all(b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\nConnection: close, x-hop\r\nx-hop: remove-me\r\nSet-Cookie: a=1\r\nSet-Cookie: b=2\r\n\r\nD\r\ndata: first\n\n\r\n").await.unwrap(); io.flush().await.unwrap();
                    tokio::select! {
                        _=ready.notified()=>{},
                        _=io.read_u8()=>{ let _=tx.send("DISCONNECTED".into()); return; }
                    }
                    let _=io.write_all(b"C\r\ndata: last\n\n\r\n0\r\n\r\n").await;
                }
            });
        }
    });
    Fixture {
        addr,
        certificate,
        requests,
        release,
        task,
    }
}
struct Running {
    url: String,
    server: Arc<Server>,
    task: tokio::task::JoinHandle<()>,
    _temp: tempfile::TempDir,
}
impl Drop for Running {
    fn drop(&mut self) {
        self.task.abort();
    }
}
async fn running(config: &str) -> Running {
    let temp = tempfile::tempdir().unwrap();
    let logger = Arc::new(Logger::new(temp.path().join("proxy.log")));
    let config = Config::parse(&format!(
        "listen_port: 7889\nrequest_timeout_seconds: 3\n{config}"
    ))
    .unwrap();
    let server = Arc::new(Server::new(config, logger));
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    let task = tokio::spawn(
        server
            .clone()
            .serve(listener, std::future::pending())
            .map(|r| r.unwrap()),
    );
    Running {
        url,
        server,
        task,
        _temp: temp,
    }
}
use futures_util::FutureExt;
fn trust(running: &Running, fixture: &Fixture, endpoint: &str) {
    let mut client = reqwest::Client::builder()
        .no_proxy()
        .retry(reqwest::retry::never())
        .redirect(reqwest::redirect::Policy::none())
        .timeout(Duration::from_secs(3))
        .add_root_certificate(fixture.certificate.clone());
    if endpoint == "none" {
        client = client
            .resolve("upstream.invalid", fixture.addr)
            .resolve("developers.openai.com", fixture.addr);
    } else {
        client = client.proxy(reqwest::Proxy::all(endpoint).unwrap());
    }
    running
        .server
        .clients
        .lock()
        .unwrap()
        .insert(endpoint.into(), client.build().unwrap());
}
fn http() -> reqwest::Client {
    reqwest::Client::builder().no_proxy().build().unwrap()
}

#[tokio::test]
async fn tls_connect_and_https_connect_stream_before_completion() {
    for mode in ["http", "https"] {
        let mut fixture = fixture(mode, "sse").await;
        let endpoint = format!(
            "{mode}://test%40user:p%3Ass%40word@localhost:{}",
            fixture.addr.port()
        );
        let running=running(&format!("proxies:\n  selected: {endpoint}\nrouting:\n  api_key_fallback: selected\nbase_url:\n  api_key: https://upstream.invalid/v1\n")).await;
        trust(&running, &fixture, &endpoint);
        let response = http()
            .post(format!("{}/v1/responses?private=hidden", running.url))
            .bearer_auth("model-secret")
            .header("connection", "x-hop")
            .header("x-hop", "private-hop")
            .header("cookie", "private-cookie")
            .body("request-body")
            .send()
            .await
            .unwrap();
        assert_eq!(response.status(), 200);
        assert!(!response.headers().contains_key("x-hop"));
        assert_eq!(response.headers().get_all("set-cookie").iter().count(), 2);
        let mut stream = response.bytes_stream();
        let first = tokio::time::timeout(Duration::from_secs(2), stream.next())
            .await
            .unwrap()
            .unwrap()
            .unwrap();
        assert_eq!(first, "data: first\n\n");
        fixture.release.notify_one();
        let mut rest = Vec::new();
        while let Some(b) = stream.next().await {
            rest.extend_from_slice(&b.unwrap());
        }
        assert_eq!(rest, b"data: last\n\n");
        let connect = fixture.requests.recv().await.unwrap().to_lowercase();
        assert!(connect.contains("proxy-authorization: basic dgvzd"));
        let request = fixture.requests.recv().await.unwrap().to_lowercase();
        assert!(request.starts_with("post /v1/responses?private=hidden "));
        assert!(request.contains("authorization: bearer model-secret"));
        assert!(request.ends_with("request-body"));
        assert!(!request.contains("private-hop"));
        assert!(!request.contains("private-cookie"));
        assert!(!request.contains("proxy-authorization"));
        let raw = std::fs::read_to_string(running._temp.path().join("proxy.log")).unwrap();
        for secret in [
            "model-secret",
            "hidden",
            "request-body",
            "test%40user",
            "p%3Ass",
        ] {
            assert!(!raw.contains(secret));
        }
        assert!(raw.contains("request_finished"));
    }
}

#[tokio::test]
async fn ordered_probes_are_credential_free_and_repeated_per_request() {
    let mut fixture = fixture("direct", "redirect").await;
    let dead = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let dead_port = dead.local_addr().unwrap().port();
    drop(dead);
    let running=running(&format!("proxies:\n  dead: http://127.0.0.1:{dead_port}\nrouting:\n  api_key_fallback: [dead, none]\nbase_url:\n  api_key: https://upstream.invalid/v1\n")).await;
    trust(&running, &fixture, "none");
    let client = reqwest::Client::builder()
        .no_proxy()
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .unwrap();
    for _ in 0..2 {
        let response = client
            .post(format!("{}/responses?secret=query", running.url))
            .bearer_auth("model-secret")
            .body("private-body")
            .send()
            .await
            .unwrap();
        assert_eq!(response.status(), 302);
        let probe = fixture.requests.recv().await.unwrap().to_lowercase();
        assert!(probe.starts_with("head / http"));
        for s in ["authorization", "private-body", "query", "model-secret"] {
            assert!(!probe.contains(s));
        }
        let request = fixture.requests.recv().await.unwrap();
        assert!(request.starts_with("POST /v1/responses?secret=query "));
    }
    assert!(
        fixture.requests.try_recv().is_err(),
        "redirect must not be followed"
    );
}

#[tokio::test]
async fn mcp_strips_credentials_and_only_forwards_protocol_headers() {
    let mut fixture = fixture("direct", "redirect").await;
    let running = running("routing:\n  mcp_fallback: none\n").await;
    trust(&running, &fixture, "none");
    let response = reqwest::Client::builder()
        .no_proxy()
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .unwrap()
        .post(format!("{}/mcp/openaiDeveloperDocs?q=1", running.url))
        .bearer_auth("model-secret")
        .header("cookie", "private-cookie")
        .header("x-private", "private")
        .header("mcp-session-id", "session-1")
        .body("{}")
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), 302);
    let request = fixture.requests.recv().await.unwrap().to_lowercase();
    assert!(request.starts_with("post /mcp?q=1 "));
    assert!(request.contains("mcp-session-id: session-1"));
    for s in ["authorization", "cookie", "x-private", "model-secret"] {
        assert!(!request.contains(s));
    }
}

#[tokio::test]
async fn request_limits_duplicates_and_chunked_upload() {
    let mut fixture = fixture("direct", "redirect").await;
    let running = running(
        "routing:\n  api_key_fallback: none\nbase_url:\n  api_key: https://upstream.invalid/v1\n",
    )
    .await;
    trust(&running, &fixture, "none");
    for (extra, status) in [
        ("Content-Length: 33554433\r\n", 413),
        ("Expect: 100-continue\r\nContent-Length: 2\r\n", 417),
        ("Upgrade: websocket\r\n", 426),
        ("Authorization: Bearer duplicate\r\n", 400),
        ("Content-Length: 2\r\nTransfer-Encoding: chunked\r\n", 400),
        ("Content-Length: 2\r\nContent-Length: 2\r\n", 400),
    ] {
        let mut socket = tokio::net::TcpStream::connect(running.url.trim_start_matches("http://"))
            .await
            .unwrap();
        socket.write_all(format!("POST /responses HTTP/1.1\r\nHost: local\r\nAuthorization: Bearer model-secret\r\n{extra}\r\n").as_bytes()).await.unwrap();
        let mut output = String::new();
        tokio::time::timeout(Duration::from_secs(2), socket.read_to_string(&mut output))
            .await
            .unwrap()
            .unwrap();
        assert!(
            output.starts_with(&format!("HTTP/1.1 {status}")),
            "{output}"
        );
    }
    let mut socket = tokio::net::TcpStream::connect(running.url.trim_start_matches("http://"))
        .await
        .unwrap();
    socket.write_all(b"POST /responses HTTP/1.1\r\nHost: local\r\nAuthorization: Bearer model-secret\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n2\r\nde\r\n0\r\n\r\n").await.unwrap();
    let mut output = String::new();
    socket.read_to_string(&mut output).await.unwrap();
    assert!(output.starts_with("HTTP/1.1 302"));
    assert!(fixture.requests.recv().await.unwrap().ends_with("abcde"));
}

#[tokio::test]
async fn disconnect_cancels_upstream_and_stream_timeout_does_not_replay() {
    for disconnect in [true, false] {
        let mut fixture = fixture("direct", "sse").await;
        let running=running("routing:\n  api_key_fallback: none\nbase_url:\n  api_key: https://upstream.invalid/v1\n").await;
        trust(&running, &fixture, "none");
        let response = http()
            .post(format!("{}/responses", running.url))
            .bearer_auth("model-secret")
            .send()
            .await
            .unwrap();
        let mut stream = response.bytes_stream();
        assert_eq!(stream.next().await.unwrap().unwrap(), "data: first\n\n");
        assert!(fixture.requests.recv().await.unwrap().starts_with("POST "));
        if disconnect {
            drop(stream);
        } else {
            assert!(
                tokio::time::timeout(Duration::from_secs(5), stream.next())
                    .await
                    .unwrap()
                    .unwrap()
                    .is_err()
            );
        }
        assert_eq!(
            tokio::time::timeout(Duration::from_secs(2), fixture.requests.recv())
                .await
                .unwrap()
                .unwrap(),
            "DISCONNECTED"
        );
        assert!(
            fixture.requests.try_recv().is_err(),
            "failed streaming request must never be replayed"
        );
    }
}
