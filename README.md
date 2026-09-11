# coding-agent-proxy

A local macOS reverse proxy that routes coding-agent requests through a specific outbound proxy based on the currently signed-in account.

Currently supports **Codex with ChatGPT sign-in**. Account-to-proxy mappings live in YAML and are reloaded for every request. Claude and Gemini adapters are not implemented.

```text
Codex → coding-agent-proxy (127.0.0.1:8787)
      → current account ID from auth.json
      → account-to-proxy mapping
      → designated HTTP CONNECT / HTTPS CONNECT / SOCKS5 proxy
      → ChatGPT Codex upstream
```

## Features

- **Per-account routing:** match `tokens.account_id` exactly to an explicit proxy mapping.
- **Live configuration:** reread configuration and credentials for every request. In-flight requests retain their original identity and route.
- **Fail-closed forwarding:** reject missing mappings, invalid configuration, and unavailable proxies without switching accounts or falling back to a direct connection.
- **Identity checks:** require a Bearer token matching the current `tokens.access_token`; validate `ChatGPT-Account-Id` when supplied.
- **HTTP/SSE passthrough:** preserve request bodies, query parameters, upstream status codes, and streaming data while filtering hop-by-hop headers and rebuilding HTTP framing.
- **Local operation:** listen on IPv4 loopback only. The process clears inherited proxy environment variables and uses its YAML configuration for outbound routing.
- **Structured logs:** record request IDs, selected routes, response status, timing, and failures.

The service does not manage an account pool, rotate accounts, refresh credentials, map models, or convert API protocols. Redirects, caching, and cookie storage are disabled.

## Requirements

- macOS 14 or later.
- Swift 6 or later, with a compatible Xcode or Command Line Tools installation.
- Codex credentials saved to an `auth.json` file by ChatGPT sign-in.
- At least one working outbound proxy. See [Multiple proxy services with mihomo and Clash](#multiple-proxy-services-with-mihomo-and-clash).

## Quick start

```sh
git clone https://github.com/avegetablechicken/coding-agent-proxy.git
cd coding-agent-proxy
swift build -c release
cp config.example.yaml config.yaml
```

The initial build downloads [Yams](https://github.com/jpsim/Yams), the YAML dependency.

Edit `config.yaml`:

```yaml
listen_port: 8787
auth_file: "~/.codex/auth.json"
upstream_base_url: "https://chatgpt.com/backend-api/codex"
request_timeout_seconds: 300

proxies:
  us: "http://127.0.0.1:8101"
  jp: "socks5://127.0.0.1:8102"

accounts:
  "replace-with-us-account-id": us
  "replace-with-jp-account-id": jp
```

Replace each account placeholder with the corresponding `tokens.account_id` from that account's credential file. Do not put access tokens in this YAML file. Multiple accounts may share one proxy. Labels such as `us` and `jp` are arbitrary: the application does not create proxy nodes, determine their location, or verify their country.

`~` expands to the home directory of the user running the service. Relative paths resolve from the working directory at launch.

```sh
.build/release/coding-agent-proxy --config config.yaml --check
.build/release/coding-agent-proxy --config config.yaml
```

`--check` validates configuration and the current account mapping; it does not test network reachability. Account mappings, proxy endpoints, credentials, and timeouts take effect on the next request. Changing the listen port requires a restart. Stop with Ctrl-C or SIGTERM.

## Connect Codex

Merge the following into `~/.codex/config.toml`. Place the top-level `model_provider` setting before any TOML table definitions, and avoid duplicate keys or tables.

```toml
model_provider = "coding_agent_proxy"

[model_providers.coding_agent_proxy]
name = "Coding Agent Proxy"
base_url = "http://127.0.0.1:8787/v1"
wire_api = "responses"
requires_openai_auth = true
supports_websockets = false
```

Keep your existing model settings and restart the client after changing its provider configuration. This setup uses HTTP/SSE; the proxy does not forward WebSockets. Remove or restore the `model_provider` setting to return to your previous provider. This project does not edit Codex configuration automatically.

The credential file must contain `tokens.account_id` and `tokens.access_token`. Credentials stored only in a keychain and API-key-only credential files are not supported. The client is responsible for signing in, refreshing tokens, and saving them to the configured file.

The local paths `/responses`, `/v1/responses`, and `/backend-api/codex/responses` map to `/responses` under `upstream_base_url`. Subpaths such as `/responses/compact` and query parameters are preserved. Other paths are appended to the upstream base URL. There is no Chat Completions-to-Responses conversion or conversion of ChatGPT credentials into public API keys.

Check that the listener is running:

```sh
curl --noproxy '*' http://127.0.0.1:8787/health
```

A successful health response confirms only that the listener is alive, not that credentials, mappings, or the upstream service are available.

## Multiple proxy services with mihomo and Clash

[mihomo](https://github.com/MetaCubeX/mihomo) is the proxy core used by compatible Clash clients. One core can expose several local proxy services at once, each pinned to a different outbound node. For example:

| Account mapping | Local endpoint | Fixed outbound node |
| --- | --- | --- |
| `us` | `127.0.0.1:8101` | `US-Node` |
| `jp` | `127.0.0.1:8102` | `JP-Node` |

Use a Clash client with a **mihomo-compatible core**. Older Clash cores may not support custom `listeners`. System Proxy and TUN mode are not required for these explicit local connections.

### 1. Add dedicated listeners

Add the following to your mihomo configuration, or use your Clash client's persistent profile override/merge mechanism. If a `listeners` list already exists, append these entries instead of creating a duplicate YAML key. Replace `US-Node` and `JP-Node` with exact names of nodes available in the active configuration.

```yaml
listeners:
  - name: coding-us
    type: mixed
    listen: 127.0.0.1
    port: 8101
    udp: false
    users: []
    proxy: US-Node

  - name: coding-jp
    type: mixed
    listen: 127.0.0.1
    port: 8102
    udp: false
    users: []
    proxy: JP-Node
```

Each `mixed` listener accepts HTTP CONNECT and SOCKS5. Its `proxy` field sends traffic directly to the named outbound node. Using a concrete node keeps the route independent of changes to a shared selector group. If you deliberately use a proxy group instead, its selection and fallback policy determine the actual exit; keep it restricted to the intended region and exclude `DIRECT` when direct access must be prevented.

`users: []` disables inbound authentication for these loopback listeners, matching this application's unauthenticated local proxy connections. Authentication to a remote proxy can still be handled by mihomo itself.

### 2. Configure the outbound nodes

If your Clash profile already supplies the nodes, keep its existing definitions and use their exact names above. If your provider supplies authenticated HTTPS CONNECT proxies, the following illustrates the equivalent mihomo `proxies` entries:

```yaml
proxies:
  - name: US-Node
    type: http
    server: us-proxy.example.com
    port: 443
    username: REPLACE_WITH_US_USERNAME
    password: REPLACE_WITH_US_PASSWORD
    tls: true

  - name: JP-Node
    type: http
    server: jp-proxy.example.com
    port: 443
    username: REPLACE_WITH_JP_USERNAME
    password: REPLACE_WITH_JP_PASSWORD
    tls: true
```

These reserved example domains and credentials are placeholders, not working proxies. Use the protocol, port, TLS settings, and credentials required by your provider. Other mihomo-supported node types can be used behind the same listeners. Keep real node definitions and subscription URLs in your private mihomo/Clash configuration.

### 3. Load the configuration

**Clash client:** save the override, reload the profile or restart its core, and inspect the effective configuration to confirm both listeners are present. Exact menu names vary by client. Use persistent overrides because subscription refreshes can replace direct edits to a downloaded profile.

**Standalone mihomo on macOS:** install with Homebrew if needed:

```sh
brew install mihomo
```

The Homebrew configuration directory is usually `/opt/homebrew/etc/mihomo` on Apple Silicon or `/usr/local/etc/mihomo` on Intel. For a standalone configuration, combine the listener and node sections above with these top-level settings in a private `config.yaml`:

```yaml
allow-lan: false
bind-address: 127.0.0.1
mode: rule
log-level: info
rules:
  - MATCH,REJECT
```

The named listener routes select their configured nodes directly; the final rule rejects traffic that reaches ordinary rule routing. This rule is for the standalone example, not a replacement for an existing Clash profile's rules.

Validate and run your configuration, replacing the directory with its actual location:

```sh
mihomo -t -d /path/to/private/mihomo -f /path/to/private/mihomo/config.yaml
mihomo -d /path/to/private/mihomo -f /path/to/private/mihomo/config.yaml
```

If Homebrew manages the configuration at its default location, you can run it as a service instead:

```sh
brew services start mihomo
# After editing the configuration of an existing service:
brew services restart mihomo
```

Choose either a Clash-managed core or a standalone core for these ports. Do not start two processes listening on the same addresses and ports.

### 4. Verify each exit and connect the application

Test each listener independently:

```sh
curl --noproxy '' --proxy http://127.0.0.1:8101 --max-time 20 https://api.ipify.org
curl --noproxy '' --proxy socks5h://127.0.0.1:8102 --max-time 20 https://api.ipify.org
```

These commands contact an external IP-check service through the selected node. Compare the results with your provider's expected exits; an IP response alone does not establish a country or guarantee access to the Codex upstream. `socks5h` is curl's remote-DNS option; use `socks5://` in this application's YAML.

The `proxies` entries in the quick-start configuration already match these listener ports. Add the real account mappings, run `--check`, start the application, and inspect `route_selected` events to confirm the account and local endpoint selected for each request.

For another region, add a node, give it a listener on a unique port, and add the corresponding application proxy label and account mapping.

Reference: [mihomo listener fields](https://wiki.metacubex.one/en/config/inbound/listeners/) and [official configuration examples](https://github.com/MetaCubeX/mihomo/blob/Meta/docs/config.yaml).

## Logs

Logs are written to stderr and to `logs/proxy.log` beside the application configuration file. Override the file location with `--log-file /path/to/proxy.log`.

```sh
tail -F logs/proxy.log
```

Each line is JSON with a UTC timestamp. Log files use mode `0600`, rotate at 5 MiB, and retain one backup as `proxy.log.1`. If file logging fails, the service reports it on stderr and continues console logging.

| Event | Meaning |
| --- | --- |
| `current_route` | Account ID and proxy configured at startup; not a connectivity test. |
| `route_unavailable` | Startup credentials or mapping could not be read; later requests retry reading configuration. |
| `request_received` | Request method, path without query, and unique request ID. |
| `route_selected` | Account and proxy actually selected for this request. |
| `upstream_response` | Upstream HTTP status and time to response headers (`headers_ms`). |
| `request_finished` | Transfer completed, including status, duration, and received bytes; check status for upstream errors. |
| `request_rejected` / `request_failed` | Authentication, configuration, connection, or streaming failure with diagnostic context. |

Logs contain **full account IDs and proxy endpoints**. They do not record tokens, authentication headers, query parameters, or request/response bodies. Keep logs private. `/health` requests are excluded from request logs.

## Limits and troubleshooting

- The upstream must use HTTPS and a public service hostname. IP addresses and local hostnames are rejected because URLSession can implicitly bypass proxies for loopback destinations.
- Proxy URLs require an explicit port and support `http`, `https`, or `socks5`. Proxy credentials in these URLs are unsupported; mihomo can handle remote authentication as shown above.
- Inbound limits: 32 MiB request body, 64 KiB headers, 128 concurrent connections, and a 30-second read timeout. Content-Length and chunked uploads are supported; each connection handles one request.
- `Expect: 100-continue` returns HTTP 417. WebSocket Upgrade returns HTTP 426.
- SSE is flushed at line boundaries or 16 KiB; ordinary responses use 16 KiB chunks. URLSession may add its own internal buffering.
- `request_timeout_seconds` accepts 1–3600 seconds and configures both the upstream request timeout and the total resource timeout. A failure after streaming starts closes the connection without inserting a JSON error into the stream.
- Local HTTP 401 means the Bearer token does not match the current credential file. HTTP 409 means the account header does not match. HTTP 502 indicates a routing/configuration or upstream connection failure. Upstream HTTP errors retain their original status and body.
- If a mihomo listener refuses connections, confirm the effective profile contains it, its node name is valid, and the port is not occupied. If the exit changes unexpectedly, inspect the listener's node/group selection.
- After rebuilding a running service, restart that process to use the new executable.

## Development

```sh
swift build
swift test
python3 scripts/integration.py
```

Swift tests cover configuration, identity validation, path mapping, HTTP framing, header filtering, logging, and early SSE delivery. The Python integration test uses synthetic credentials and local CONNECT probes to verify route selection, live reload, authentication rejection, missing mappings, logging, and failure without fallback. These tests do not call a real model or prove live provider connectivity.

| File | Responsibility |
| --- | --- |
| `Sources/RegionProxy/main.swift` | CLI, startup, and process lifecycle. |
| `Sources/RegionProxyCore/Configuration.swift` | YAML validation, credentials, and proxy mappings. |
| `Sources/RegionProxyCore/Forwarder.swift` | Identity source abstraction and upstream transport. |
| `Sources/RegionProxyCore/HTTP.swift` | Local HTTP listener and framing. |
| `Sources/RegionProxyCore/RequestLogger.swift` | Structured logs and rotation. |

## Acknowledgments

Special thanks to **[Copool](https://github.com/AlickH/Copool)** and its contributors. Copool's local proxy implementation informed the technology choices here: Swift 6, Network.framework (`NWListener` / `NWConnection`), `URLSession.AsyncBytes`, and per-session `ProxyConfiguration`. This project's HTTP parsing and account routing are implemented separately; it does not include Copool's account pool, account rotation, quota management, model mapping, or protocol conversion features.

Thanks also to [Yams](https://github.com/jpsim/Yams) for YAML parsing and [mihomo](https://github.com/MetaCubeX/mihomo) for the proxy core used in the multi-listener setup.
