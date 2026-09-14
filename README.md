# coding-agent-proxy

A macOS loopback reverse proxy for Codex model requests, ChatGPT account APIs and
OpenAI documentation MCP. It selects an outbound proxy by matching ChatGPT or
API Key credentials. HTTP/SSE data is passed through without model or protocol conversion.

## Configuration

Requires macOS 14+, Swift 6+, and Homebrew Python 3.11+ when reading Codex provider
metadata. Build and create a local configuration:

```sh
swift build -c release
cp config.example.yaml config.yaml
```

```yaml
listen_port: 7889
auth_file: "~/.codex/auth.json"
request_timeout_seconds: 300

base_url:
  account: "https://chatgpt.com/backend-api"
  api_key: "https://api.openai.com/v1"

proxies:
  us: "http://127.0.0.1:7891"
  jp: "http://127.0.0.1:7892"

routing:
  account:
    "replace-with-account-id": jp
  api_key:
    - name: openai
      api_key_env: OPENAI_API_KEY
      proxy: us
  # account_fallback: jp
  # api_key_fallback: us
  # mcp_fallback: jp
```

`base_url.account` is the shared ChatGPT backend root. Model endpoints use its
`/codex` namespace; usage and plugin APIs use `/wham` and `/ps`. The legacy
`/backend-api/codex` base is normalized for account requests. `base_url.api_key`
is the default API Key upstream and the destination for unmatched keys when
`routing.api_key_fallback` is configured.

`proxies` defines named HTTP CONNECT, HTTPS CONNECT or SOCKS5 endpoints. The
reserved value `none` selects direct access, and a proxy alias may also map to
`none`. Proxy URLs require explicit ports. The service clears inherited HTTP/SOCKS
proxy environment variables and disables system/PAC proxy discovery for direct routes.

`routing.account` maps `tokens.account_id` from `auth.json` to proxy names. A
request must match the saved access token; a supplied account header must also
match. Credentials stored only in a keychain are unsupported. Codex remains
responsible for login and token refresh.

`routing.api_key` is a list so multiple keys can share a provider but select
different proxies. Each entry has `proxy`, a `name` and/or `api_key_env`, and
optionally `api_key_file` or `upstream_base_url`. Do not combine `api_key_env`
and `api_key_file`. `name` selects a Codex provider and its `env_key`; `openai`
uses `OPENAI_API_KEY`. An explicit `api_key_env` overrides the variable name.
Without `name`, `api_key_env` can reverse-match a Codex provider. Ambiguous matches
are rejected. File-backed entries do not depend on Codex provider metadata.

An entry's explicit `upstream_base_url` always takes priority. The built-in
`openai` provider otherwise uses `base_url.api_key`, independently of Codex's
`openai_base_url`. Custom providers use their Codex `base_url` when present,
then fall back to `base_url.api_key`.
All upstreams must be HTTPS public hostnames. API Keys are not converted into
ChatGPT login credentials, and ChatGPT tokens are not converted into API Keys.

| Fallback field | When used | If omitted/null |
| --- | --- | --- |
| `routing.account_fallback` | A verified ChatGPT token has no account mapping | Reject the account route |
| `routing.api_key_fallback` | A supplied Bearer token matches no configured credential | Reject the API request |
| `routing.mcp_fallback` | Public documentation MCP cannot select a credential route | Direct MCP access |

Each fallback references a name under `proxies`, or `none` for explicit direct
access. Explicit matched routes take priority, including routes selecting `none`.
Missing authentication does not activate account/API fallback. Duplicate credential
matches remain errors for model/usage requests; public MCP uses its own fallback.
Once an outbound proxy is selected, connection/authentication failures do not switch
proxies or silently fall back to direct access.

YAML is loaded once at startup. Account mappings, upstreams, proxy credentials,
fallbacks and timeouts require a restart after editing. `auth.json` and API Key
files are read per request so credential rotation can take effect without restart.
Codex provider configuration lookup retains its existing request-time behavior.

For environment-backed API Keys, process variables take priority. If a variable
is absent, the service runs the user's login/interactive zsh, bash or sh at
request time and reads that one exported variable. For zsh this follows the usual
`.zshenv`, `.zprofile`, `.zshrc` and `.zlogin` loading rules. Startup output is
ignored; lookup times out after 3 seconds and never logs values. Shell scripts
must complete without terminal interaction. Requests already matched to a
ChatGPT login do not start a shell to resolve unrelated API keys.

```sh
.build/release/coding-agent-proxy --config config.yaml --check
.build/release/coding-agent-proxy --config config.yaml
```

`--check` validates configuration and credentials, not proxy reachability. Stop
with Ctrl-C or SIGTERM. An MCP-only service can omit account and API Key routes.

### Migrate older configurations

Legacy top-level `upstream_base_url` / `account_upstream_base_url`,
`api_key_upstream_base_url`, `accounts`, `api_key_providers`,
`openai_fallback_proxy` and `mcp_fallback_proxy` are accepted for migration.
Do not mix old upstream keys with `base_url`, or old routing keys with `routing`.
The migration command writes a private file without printing its credentials:

```sh
.build/release/coding-agent-proxy --config config.yaml --write-config config.new.yaml
.build/release/coding-agent-proxy --config config.new.yaml --check
```

It preserves proxy URLs and credential sources and normalizes the account base
to `/backend-api`. Back up the active config before replacing it, then restart.

## Connect Codex

Top-level Codex settings (before any TOML table):

```toml
openai_base_url = "http://127.0.0.1:7889/v1"
chatgpt_base_url = "http://127.0.0.1:7889/backend-api"
```

The first setting controls model requests; the second independently controls
ChatGPT backend requests. Codex only adds `/backend-api` automatically for
recognized official hostnames, so include it for a loopback URL. Restart Codex
after editing. The service uses HTTP/SSE; WebSocket upgrades are unsupported.

For matched ChatGPT credentials, `/responses`, `/v1/responses` and
`/backend-api/codex/responses` map to the same model endpoint. Official
`/backend-api/...` paths retain their full path, including plugin listing at
`/backend-api/ps/plugins/installed` and analytics events. The usage endpoints
`/backend-api/wham/usage` and `/backend-api/wham/rate-limit-reset-credits` require
GET and a matched ChatGPT login; API Keys cannot read subscription limits.

The explicit upstream URL form also works, for example:
`http://127.0.0.1:7889/https://chatgpt.com/backend-api/codex/responses` or
`http://127.0.0.1:7889/https://provider.example.com/v1/responses`.
The HTTPS origin and API path must match the credential's configured upstream.
There is no arbitrary unauthenticated URL forwarding or `?base_url=` parameter.

### OpenAI documentation MCP

```toml
[mcp_servers.openaiDeveloperDocs]
url = "http://127.0.0.1:7889/mcp/openaiDeveloperDocs"
enabled = true
```

No helper or per-session configuration is required. The destination is fixed to
`https://developers.openai.com/mcp`. A matching optional Bearer credential selects
the same route as model requests. Otherwise `routing.mcp_fallback` applies;
with the URL-only configuration above, requests normally use that fallback.
Model tokens, account IDs, cookies and other private headers are not sent to the
public MCP upstream. MCP session/protocol headers, JSON and SSE are preserved.

## Run as a background service

```sh
python3 scripts/service.py install
python3 scripts/service.py status
```

The launchd job `local.coding-agent-proxy` runs at login and restarts after exits.
Runtime files live in `~/Library/Application Support/coding-agent-proxy`.
Installation copies `config.yaml` once; updates preserve the runtime config.
Edit that copy and restart to apply changes. Absolute credential paths are
recommended. The supervisor can start Homebrew mihomo if it is not already running.
Existing listeners are left untouched; the supervisor waits for the port to become free.

After code changes:

```sh
swift build -c release
python3 scripts/service.py update
python3 scripts/service.py restart
```

`update` copies the executable and supervisor without restarting. `restart`
briefly interrupts active requests. `uninstall` removes service registration
while retaining configuration and logs.

```sh
curl --noproxy '*' http://127.0.0.1:7889/health
tail -F "$HOME/Library/Application Support/coding-agent-proxy/logs/proxy.log"
```

Health confirms that the listener is running, not upstream connectivity.

## Proxy username/password authentication

Proxy entries retain their string format and may include credentials:

```yaml
proxies:
  authenticated_http: "http://proxy-user:proxy-password@proxy.example.com:8080"
  authenticated_https: "https://proxy-user:proxy-password@proxy.example.com:8443"
  authenticated_socks: "socks5://proxy-user:proxy-password@proxy.example.com:1080"
```

The system networking stack supplies the credentials to the proxy, separately
from the model request's Bearer token. Percent-encode reserved characters in
usernames/passwords: for example, `user@example` and `p:ss@word` become
`user%40example:p%3Ass%40word`. Supply both fields; an empty password is accepted
for HTTP(S), while SOCKS5 requires 1–255 UTF-8 bytes per field. HTTP usernames
cannot contain a colon. Credentials containing control characters are rejected.

Proxy endpoint logs omit both username and password. Unauthenticated URLs and
`none` remain supported. Restart the service after changing proxy credentials
in YAML. An authentication failure does not switch to a different proxy or direct
access.

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

`users: []` disables inbound authentication for these loopback listeners, for the unauthenticated local proxy URLs in these examples. Authentication to a remote proxy can still be handled by mihomo itself.

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
| `route_unavailable` | Startup credentials or mapping could not be read; later requests retry credential loading using the startup configuration. |
| `request_received` | Request method, path without query, and unique request ID. |
| `route_selected` | Account and proxy actually selected for this request. |
| `upstream_response` | Upstream HTTP status and time to response headers (`headers_ms`). |
| `request_finished` | Transfer completed, including status, duration, and received bytes; check status for upstream errors. |
| `request_rejected` / `request_failed` | Authentication, configuration, connection, or streaming failure with diagnostic context. |

Logs contain **full account IDs and proxy endpoints**. They do not record tokens, authentication headers, query parameters, or request/response bodies. Keep logs private. `/health` requests are excluded from request logs.

## Limits and troubleshooting

- The upstream must use HTTPS and a public service hostname. IP addresses and local hostnames are rejected because URLSession can implicitly bypass proxies for loopback destinations.
- Proxy URLs require an explicit port and support `http`, `https`, or `socks5`. Optional username/password authentication uses `scheme://username:password@host:port`. Credentials are removed from logged proxy URLs.
- Inbound limits: 32 MiB request body, 64 KiB headers, 128 concurrent connections, and a 30-second read timeout. Content-Length and chunked uploads are supported; each connection handles one request.
- `Expect: 100-continue` returns HTTP 417. WebSocket Upgrade returns HTTP 426.
- SSE is flushed at line boundaries or 16 KiB; ordinary responses use 16 KiB chunks. URLSession may add its own internal buffering.
- `request_timeout_seconds` accepts 1–3600 seconds and configures both the upstream request timeout and the total resource timeout. A failure after streaming starts closes the connection without inserting a JSON error into the stream.
- Local HTTP 401 means the Bearer token is missing/malformed, or no credential matches and OpenAI fallback is disabled. HTTP 409 means the account header does not match or the token matches multiple routes. HTTP 502 indicates a routing/configuration or upstream connection failure. Upstream HTTP errors retain their original status and body.
- If a mihomo listener refuses connections, confirm the effective profile contains it, its node name is valid, and the port is not occupied. If the exit changes unexpectedly, inspect the listener's node/group selection.
- After rebuilding a running service, restart that process to use the new executable.

## Development

```sh
swift build
swift test
python3 scripts/integration.py
python3 scripts/test_proxy_auth.py
```

Swift tests cover configuration, identity validation, path mapping, HTTP framing, header filtering, logging, and early SSE delivery. The Python integration test uses synthetic credentials and local CONNECT probes to verify route selection, startup configuration snapshots and restarts, authentication rejection, missing mappings, logging, explicit OpenAI fallback through its designated proxy, and refusal without a configured fallback. These tests do not call a real model or prove live provider connectivity.

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
