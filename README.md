# coding-agent-proxy

A local macOS reverse proxy that selects an upstream service and outbound proxy by matching the request's Bearer credential.

Supports **Codex with ChatGPT sign-in** and **Bearer routing to multiple API Key providers**. Routes are loaded from YAML once at startup. API protocols are passed through; Claude and Gemini protocol adapters are not implemented.

```text
Codex → coding-agent-proxy (127.0.0.1:8787)
      → match ChatGPT access token or configured API Key
      → account/provider route and designated proxy
      → HTTP CONNECT / HTTPS CONNECT / SOCKS5 proxy
      → matching ChatGPT or API provider upstream
```

## Features

- **Per-account routing:** match `tokens.account_id` exactly to an explicit proxy mapping.
- **Startup configuration:** keep the loaded YAML in memory; edits require a restart. Credentials are still refreshed per request.
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

`--check` validates configuration, all credential sources, the current account mapping and duplicate credentials; it does not test network reachability. Account mappings, proxy endpoints, timeouts, and other YAML changes require a restart. Credential file changes take effect on the next request. Stop with Ctrl-C or SIGTERM.

## Default upstreams

```yaml
upstream_base_url: "https://chatgpt.com/backend-api/codex"
api_key_upstream_base_url: "https://api.openai.com/v1"
```

The first setting controls account routing; the second is the default for API Key
routes and the destination for unmatched-token fallback. Both must be real HTTPS
upstream addresses. The fallback still requires `openai_fallback_proxy` (a proxy
name or explicit `none`); setting a default URL alone does not enable fallback.

## Bearer routing: ChatGPT and API Key providers

One `config.yaml` and listener can serve ChatGPT login requests and multiple API
Key providers at the same time. Keep `auth_file`, `accounts`, and the top-level
`upstream_base_url` for ChatGPT. Add providers with their own real upstream URLs:

```yaml
api_key_providers:
  - name: openai
    proxy: us
    # Uses Codex base_url, then top-level api_key_upstream_base_url
  - name: provider-a
    upstream_base_url: "https://a.example.com/v1"
    proxy: us
    api_key_file: "~/.config/coding-agent-proxy/provider-a.key"
  - api_key_env: PROVIDER_B_API_KEY
    upstream_base_url: "https://b.example.com/v1"
    proxy: jp
```

These entries extend the existing configuration; see [config.example.yaml](config.example.yaml).
`proxy` references the shared `proxies` mapping. Each entry needs exactly one key
source: a file containing the raw API Key (use permissions `0600`), or an environment
variable. In environment mode, `name` is the Codex Provider ID, resolved through
`model_providers.<id>.env_key` in `$CODEX_HOME/config.toml` (default `~/.codex/config.toml`).
The built-in `openai` ID uses `OPENAI_API_KEY`. This reads the base user config;
profile files and command-line overrides are not resolved. Provider lookup uses
Homebrew Python 3.11+ (`tomllib`). With `api_key_env` alone, the proxy reverse-matches
Codex providers by `env_key` to obtain the real `base_url`.

Specify `name`, `api_key_env`, or both. An explicit `api_key_env` always supplies
the matching key, independently of the named Provider's own credential. When
`name` is present, it selects the Codex Provider whose `base_url` is read; the
explicit environment variable need not appear in that Provider's configuration.
Without `name`, reverse-match by `env_key`; multiple matches make the route
unavailable. With only `name`, use that Provider's `env_key` for authentication.

Multiple entries can share the same `name`, each with a different `api_key_env`
and outgoing `proxy`. Duplicate key values still cause ambiguous Bearer routing
and are rejected. Environment variables must be available to the proxy process,
not just its client. In file mode, `name` remains a label alongside `api_key_file`,
and no Codex provider lookup is performed. For API Key-only operation, omit both `auth_file` and `accounts`.
Upstream priority is: this configuration's explicit `upstream_base_url`, then the
resolved Codex provider's `base_url`, then top-level `api_key_upstream_base_url`
(which defaults to `https://api.openai.com/v1`). The built-in
OpenAI provider also reads Codex's `openai_base_url`. An unmatched `api_key_env`
uses the explicit upstream or that top-level default. Missing Codex config allows
that default; malformed/unreadable config fails lookup rather than guessing.
Invalid resolved URLs are rejected. The route always uses its specified `proxy`
(the example selects `us`), and never inherits the top-level ChatGPT upstream. Only the `api_key_providers` list format is supported.

Clients all use the same local base URL, for example `http://127.0.0.1:7889/v1`,
and send their original `Authorization: Bearer <token>`:

- Matching the current `auth.json` access token selects its account mapping and
  the top-level ChatGPT upstream, with `ChatGPT-Account-Id` validation.
- Matching a provider's API Key selects that provider's upstream and proxy, without
  sending a ChatGPT account header.
- If no credential matches, optional `openai_fallback_proxy: us` sends the original
  Bearer token to `api_key_upstream_base_url` through that named proxy. It also applies
  when a credential source is unavailable. There is no credential conversion and no
  implicit direct connection; use `none` to explicitly select direct access. The upstream
  decides whether the supplied token is valid.
- Without `openai_fallback_proxy`, an unknown token returns 401 when all credential
  sources are available, or 502 if any source is unavailable.
- Missing/malformed Bearer headers return 401. Multiple credential matches return
  409. These errors, account mismatch, and failures on a matched route do not trigger
  fallback. The fallback uses the top-level API Key URL and sends no ChatGPT account header.

`openai_fallback_proxy` must reference an existing entry in `proxies` or be `none`
for explicit direct access. It is disabled
by default and can be used without account or API Key mappings. Explicit upstream
paths still must match the selected route: a path naming another service is never
silently sent to OpenAI.

For clients where `OPENAI_BASE_URL` selects the endpoint, launch with:

```sh
OPENAI_BASE_URL="http://127.0.0.1:7889/v1" codex
```

The proxy routes the token it receives; it does not infer the upstream from a key's
prefix. It resolves configured provider identifiers against Codex configuration,
or uses an explicit upstream override above.
Keep upstream URLs pointed at the service provider, or use the explicit local
wrapper described below; a plain local URL without an embedded HTTPS base is rejected.
A client using a custom provider may require a command-line `base_url` override
if it ignores `OPENAI_BASE_URL`.

```sh
.build/release/coding-agent-proxy --config config.yaml --check
.build/release/coding-agent-proxy --config config.yaml
```

`--check` checks all configured credential sources, account mapping and duplicate
credentials. Credentials are loaded once per request; key file changes affect
subsequent requests. YAML configuration changes require a restart. Environment changes require a process restart.
For launchd, prefer key files because shell variables are not automatically inherited.

Methods, bodies, queries, responses and SSE pass through without protocol or model
conversion. The base URL includes the upstream API prefix, such as `/v1`;
`/v1/responses` maps to `/responses` under it. Incoming `x-api-key` and `api-key`
headers are stripped and are not alternative authentication methods. Each service
must support the requested endpoint and Bearer authentication.

## Explicit direct connections

Use the reserved value `none` to disable the outgoing HTTP/SOCKS/PAC proxy for a
route. For example:

```yaml
accounts:
  your-account-id: none
api_key_providers:
  - name: openai
    proxy: none
openai_fallback_proxy: none
```

Each setting is independent. You can also give a proxy alias the value `none`,
such as `proxies: {us: none}`. The name `none` itself is reserved and cannot be
defined as a proxy alias. If all routes are direct, `proxies` may be omitted.
Missing route or fallback settings do not imply direct access. Configured proxy
failures never switch to direct mode. Logs show `proxy_endpoint: "none"` for direct
requests. Upstream HTTPS validation and credential routing remain unchanged.

## Explicit upstream URL in the path

To configure a Codex provider directly, set its `base_url` to a local URL containing
its real HTTPS API base:

```toml
[model_providers.ShareCoder]
base_url = "http://127.0.0.1:7889/https://sharecoder.cc/v1"
```

Preserve the provider's other settings, including `env_key`. Use the actual API
prefix required by that service; `/v1` is an example. Codex appending `/responses`
produces a request to `/https://sharecoder.cc/v1/responses`, which this proxy forwards
to `https://sharecoder.cc/v1/responses`. GET `/models` and other existing methods
work the same way, with query parameters preserved. Bare HTTP upstreams are not supported.

Bearer authentication still selects the configured credential and outgoing proxy.
The explicit URL must match that credential's configured HTTPS host, port and API
base path; requests to other hosts or outside the configured path are refused.
This is not an unauthenticated arbitrary-URL proxy. When resolving a Codex provider
whose base URL already uses the local `127.0.0.1` wrapper, the embedded HTTPS base
is recovered automatically, preventing a forwarding loop. Ordinary local `/v1/...`
requests remain supported. No `?base_url=` routing parameter is implemented.

ChatGPT account authentication supports the same path form:
`http://127.0.0.1:7889/https://chatgpt.com/backend-api/codex`.
Keep the proxy's top-level `upstream_base_url` set to
`https://chatgpt.com/backend-api/codex`. Requests matching `auth.json` use the
account's configured proxy and send its access token and `ChatGPT-Account-Id`;
an appended `/responses` goes to the ChatGPT Codex backend. This is a matched
account route, separate from the optional unmatched-token OpenAI API fallback.

## Run as a macOS service

After building the release executable and creating `config.yaml`, install the
current user's launchd service. Existing listeners are left running:

```sh
swift build -c release
/usr/bin/python3 scripts/service.py install
/usr/bin/python3 scripts/service.py status
```

The LaunchAgent `local.coding-agent-proxy` starts at login, runs in the background,
and restarts after a process exits. The installer copies the release executable and
startup script to `~/Library/Application Support/coding-agent-proxy`, avoiding
launchd access failures in protected Documents/Desktop directories. On the first
installation it also copies `config.yaml`; updates preserve that
service configuration. Edit the copy in Application Support and restart the service to apply
configuration changes. Relative credential paths resolve from that directory;
use an absolute path or `~/.codex/auth.json`. It runs as your user to access your
Codex credentials; it is not a root daemon that starts before login.

If the configured listen port is occupied, the supervisor waits without stopping
any existing process. When the port becomes free, it starts the proxy. This lets
you install the service during an active session and stop the manual instance
later when convenient; the brief handover is not a zero-downtime migration.

At startup, the script checks running Homebrew mihomo jobs under both
`sh.brew.mihomo` and `homebrew.mxcl.mihomo` in user and system domains. It also
recognizes an already running Homebrew mihomo executable. If none is running,
it directly launches `$(brew --prefix)/opt/mihomo/bin/mihomo -d $(brew --prefix)/etc/mihomo`
using the standard Apple Silicon or Intel Homebrew prefix. **It never calls
`brew services start`.** Ensure that Homebrew mihomo and its configuration already
exist. A failed child startup causes launchd to retry after its restart throttle.

The supervisor stops only the mihomo child it started. An existing mihomo service
remains independently managed. If a managed child exits, both owned processes are
cleaned up and launchd restarts the supervisor. Existing external mihomo is checked
at startup only and remains its original supervisor's responsibility. Do not start
a second mihomo service while this service owns a standalone instance.

```sh
/usr/bin/python3 scripts/service.py update
/usr/bin/python3 scripts/service.py restart
/usr/bin/python3 scripts/service.py uninstall
tail -F "$HOME/Library/Application Support/coding-agent-proxy/logs/service.stdout.log" \
  "$HOME/Library/Application Support/coding-agent-proxy/logs/service.stderr.log"
```

Service output (including independently started mihomo output) is appended to these
private files; launchd does not rotate them. Application request logs continue to
use the rotating `logs/proxy.log` under the service directory. After code changes,
rebuild and run `update` to stage the new executable and script without changing
the running service or its registration. Then run `restart` when convenient to
apply the update. `install` is for first installation and refuses an existing plist.
Restarting interrupts active requests; schedule it outside an active coding session. Uninstall preserves configuration
and logs in Application Support.

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

In ChatGPT mode, the credential file must contain `tokens.account_id` and `tokens.access_token`. Credentials stored only in a keychain and API-key-only `auth.json` files are not supported; configure API Key providers above. The client is responsible for signing in, refreshing tokens, and saving them to the configured file.

The local paths `/responses`, `/v1/responses`, and `/backend-api/codex/responses` map to `/responses` under `upstream_base_url`. Subpaths such as `/responses/compact` and query parameters are preserved. Other paths are appended to the upstream base URL. There is no Chat Completions-to-Responses conversion or conversion of ChatGPT credentials into public API keys.

Check that the listener is running:

```sh
curl --noproxy '*' http://127.0.0.1:8787/health
```

A successful health response confirms only that the listener is alive, not that credentials, mappings, or the upstream service are available.

## ChatGPT account usage queries

For Codex CLI `/status` usage limits, keep the model endpoint and also set this
top-level key in `~/.codex/config.toml` (before any TOML table):

```toml
openai_base_url = "http://127.0.0.1:7889/v1"
chatgpt_base_url = "http://127.0.0.1:7889/backend-api"
```

Restart Codex after changing its config. Usage queries use `chatgpt_base_url`,
independently of the model endpoint. The service forwards GET requests for
`/backend-api/wham/usage` and `/backend-api/wham/rate-limit-reset-credits` to
the sibling `/backend-api/wham/...` paths of the configured ChatGPT upstream.
That upstream must end in `/backend-api/codex`. Incoming account query paths
retain the official `/backend-api/wham/...` structure without shortened aliases.
Keep `/backend-api` in `chatgpt_base_url`: Codex only automatically adds that
prefix for official ChatGPT hostnames, not for a loopback address.
The explicit upstream form `/https://chatgpt.com/backend-api/wham/usage` works
when its origin matches the configured ChatGPT upstream.

Queries require a matching ChatGPT access token and use that account's proxy;
the account header is checked when supplied and added to the upstream request.
API Keys and unmatched tokens cannot query ChatGPT subscription limits, even
when OpenAI API fallback is configured. Responses and query parameters are
passed through. MCP fallback does not apply. Only these two read-only account
endpoints are added; this is not a general ChatGPT backend proxy, and other
features using `chatgpt_base_url` may require additional endpoints.

## OpenAI documentation MCP

The fixed endpoint `/mcp/openaiDeveloperDocs` forwards Streamable HTTP to
`https://developers.openai.com/mcp`. Merge this into the Codex user configuration
(use your service's actual port), then restart Codex after starting the updated service:

```toml
[mcp_servers.openaiDeveloperDocs]
url = "http://127.0.0.1:7889/mcp/openaiDeveloperDocs"
enabled = true
```

No header helper or per-session configuration is required. Without a Bearer
credential, these requests use the MCP fallback below. If a client supplies a
Bearer token that uniquely matches a ChatGPT or API Key route, MCP uses that
route's proxy. Missing/malformed/unknown credentials, unavailable credential
sources, ambiguous matches, an account mismatch, or a matched account without
a mapping use `mcp_fallback_proxy` instead. This does not infer credentials from
the most recent model request or bind MCP to a Codex session.

```yaml
# Optional top-level field; references a name under proxies.
mcp_fallback_proxy: jp
```

Omit the field, set it to null, or use `none` to make the fallback direct.
An explicitly matched route using `none` also remains direct. The field is
independent of `openai_fallback_proxy`; unknown MCP tokens never select the
OpenAI API fallback. An invalid proxy name is a configuration error. Once a
proxy is selected, connection failures do not retry through another proxy or
directly. Changes to this field require a service restart.

The MCP destination is fixed, not an arbitrary URL forwarder. Model credentials,
account IDs, cookies and other private request headers are removed before
contacting the documentation site. MCP session/protocol headers, JSON bodies and
SSE responses are preserved. Logs include `service: openaiDeveloperDocs`,
`routing: credential` or `mcp_fallback`, and the selected proxy.

A service used only for public MCP can omit model credential routes; model API
requests still require configured authentication and routing. Invalid YAML is
an error for both services, not a reason to use direct access.

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
- Proxy URLs require an explicit port and support `http`, `https`, or `socks5`. Optional username/password authentication uses `scheme://username:password@host:port`. Logged endpoints omit credentials.
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
