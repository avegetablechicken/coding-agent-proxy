use crate::{Error, Result};
use serde::{Deserialize, Serialize};
use std::{collections::BTreeMap, path::PathBuf};
use url::Url;

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(untagged)]
pub enum Choice {
    One(String),
    List(Vec<String>),
}
impl Choice {
    pub fn names(&self) -> &[String] {
        match self {
            Self::One(x) => std::slice::from_ref(x),
            Self::List(x) => x,
        }
    }
    pub fn label(&self) -> String {
        self.names().join(", ")
    }
    pub fn direct() -> Self {
        Self::One("none".into())
    }
}
#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Bases {
    #[serde(default = "account_base")]
    pub account: String,
    #[serde(default = "api_base")]
    pub api_key: String,
}
fn account_base() -> String {
    "https://chatgpt.com/backend-api".into()
}
fn api_base() -> String {
    "https://api.openai.com/v1".into()
}
impl Default for Bases {
    fn default() -> Self {
        Self {
            account: account_base(),
            api_key: api_base(),
        }
    }
}
#[derive(Clone, Default, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Routing {
    #[serde(default)]
    pub account: BTreeMap<String, Choice>,
    #[serde(default)]
    pub api_key: BTreeMap<String, Choice>,
    pub account_fallback: Option<Choice>,
    pub api_key_fallback: Option<Choice>,
    pub mcp_fallback: Option<Choice>,
}
#[derive(Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Provider {
    pub name: Option<String>,
    pub api_key_env: Option<String>,
    pub api_key_file: Option<String>,
    pub upstream_base_url: Option<String>,
    pub proxy: Choice,
    #[serde(skip)]
    pub selector: Option<String>,
}
impl Provider {
    pub fn label(&self) -> &str {
        self.selector
            .as_deref()
            .or(self.name.as_deref())
            .or(self.api_key_env.as_deref())
            .unwrap_or("")
    }
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Raw {
    listen_port: u16,
    request_timeout_seconds: f64,
    #[serde(default)]
    auth_file: String,
    #[serde(default = "yes")]
    account_auth_file_only: bool,
    #[serde(default)]
    proxies: BTreeMap<String, String>,
    base_url: Option<Bases>,
    routing: Option<Routing>,
    account_upstream_base_url: Option<String>,
    upstream_base_url: Option<String>,
    api_key_upstream_base_url: Option<String>,
    accounts: Option<BTreeMap<String, Choice>>,
    api_key_providers: Option<Vec<Provider>>,
    openai_fallback_proxy: Option<Choice>,
    mcp_fallback_proxy: Option<Choice>,
}
fn yes() -> bool {
    true
}
#[derive(Clone)]
pub struct Config {
    pub listen_port: u16,
    pub request_timeout_seconds: f64,
    pub auth_file: String,
    pub account_auth_file_only: bool,
    pub proxies: BTreeMap<String, String>,
    pub base_url: Bases,
    pub routing: Routing,
    pub providers: Vec<Provider>,
}
impl Config {
    pub fn parse(text: &str) -> Result<Self> {
        let raw: Raw = serde_yaml_ng::from_str(text).map_err(|_| {
            Error::config(
                "Invalid YAML configuration; check required fields against config.example.yaml.",
            )
        })?;
        if raw.base_url.is_some()
            && (raw.account_upstream_base_url.is_some()
                || raw.upstream_base_url.is_some()
                || raw.api_key_upstream_base_url.is_some())
            || raw.routing.is_some()
                && (raw.accounts.is_some()
                    || raw.api_key_providers.is_some()
                    || raw.openai_fallback_proxy.is_some()
                    || raw.mcp_fallback_proxy.is_some())
            || raw.account_upstream_base_url.is_some() && raw.upstream_base_url.is_some()
        {
            return Err(Error::config(
                "Do not mix new and legacy configuration fields.",
            ));
        }
        let base_url = raw.base_url.unwrap_or(Bases {
            account: raw
                .account_upstream_base_url
                .or(raw.upstream_base_url)
                .unwrap_or_else(account_base),
            api_key: raw.api_key_upstream_base_url.unwrap_or_else(api_base),
        });
        let routing = raw.routing.unwrap_or(Routing {
            account: raw.accounts.unwrap_or_default(),
            api_key_fallback: raw.openai_fallback_proxy,
            mcp_fallback: raw.mcp_fallback_proxy,
            ..Default::default()
        });
        let providers = raw.api_key_providers.unwrap_or_else(|| {
            routing
                .api_key
                .iter()
                .filter(|(key, _)| !crate::url_routing::is_url_selector(key))
                .map(|(k, v)| Provider {
                    selector: Some(k.clone()),
                    proxy: v.clone(),
                    name: None,
                    api_key_env: None,
                    api_key_file: None,
                    upstream_base_url: None,
                })
                .collect()
        });
        let c = Self {
            listen_port: raw.listen_port,
            request_timeout_seconds: raw.request_timeout_seconds,
            auth_file: raw.auth_file,
            account_auth_file_only: raw.account_auth_file_only,
            proxies: raw.proxies,
            base_url,
            routing,
            providers,
        };
        c.validate()?;
        Ok(c)
    }
    pub fn read(path: &std::path::Path, migrate: bool) -> Result<Self> {
        let text = std::fs::read_to_string(path)
            .map_err(|_| Error::config("Cannot read configuration file."))?;
        if !migrate {
            return Self::parse(&text);
        }
        let mut root: serde_yaml_ng::Value = serde_yaml_ng::from_str(&text)
            .map_err(|_| Error::config("Invalid YAML configuration."))?;
        if let Some(entries) = root
            .get("routing")
            .and_then(|v| v.get("api_key"))
            .and_then(|v| v.as_sequence())
            .cloned()
        {
            let mut map = serde_yaml_ng::Mapping::new();
            for entry in entries {
                let m = entry
                    .as_mapping()
                    .ok_or(Error::config("Invalid legacy API Key mapping."))?;
                if m.keys()
                    .any(|k| !matches!(k.as_str(), Some("name" | "api_key_env" | "proxy")))
                    || (entry.get("api_key_env").is_some()
                        && entry
                            .get("name")
                            .is_some_and(|v| v.as_str() != Some("openai")))
                {
                    return Err(Error::config(
                        "Cannot migrate API Key routes without losing configuration.",
                    ));
                }
                let mut key = entry
                    .get("api_key_env")
                    .or(entry.get("name"))
                    .and_then(|v| v.as_str())
                    .ok_or(Error::config("Missing API Key identifier."))?;
                if key == "openai" && entry.get("api_key_env").is_none() {
                    key = "OPENAI_API_KEY";
                }
                let value = entry
                    .get("proxy")
                    .ok_or(Error::config("Missing proxy."))?
                    .clone();
                if map.insert(key.into(), value).is_some() {
                    return Err(Error::config("Duplicate API Key mapping after migration."));
                }
            }
            root["routing"]["api_key"] = serde_yaml_ng::Value::Mapping(map);
        }
        Self::parse(
            &serde_yaml_ng::to_string(&root)
                .map_err(|_| Error::config("Cannot migrate configuration."))?,
        )
    }
    fn validate(&self) -> Result<()> {
        if self.listen_port == 0
            || !self.request_timeout_seconds.is_finite()
            || !(1.0..=3600.0).contains(&self.request_timeout_seconds)
        {
            return Err(Error::config("Invalid port or timeout (1–3600 seconds)."));
        }
        crate::url_routing::validate_routes(&self.routing.api_key)?;
        validate_upstream(&self.base_url.account)?;
        validate_upstream(&self.base_url.api_key)?;
        let accounts = !self.routing.account.is_empty() || self.routing.account_fallback.is_some();
        if (!self.auth_file.is_empty() && !accounts)
            || (self.account_auth_file_only && accounts && self.auth_file.is_empty())
        {
            return Err(Error::config(
                "ChatGPT routing requires auth_file and account mappings or account_fallback.",
            ));
        }
        for (name, endpoint) in &self.proxies {
            if name.is_empty() || name == "none" {
                return Err(Error::config("Invalid proxy name; none is reserved."));
            }
            if endpoint != "none" {
                validate_proxy(endpoint)?;
            }
        }
        for (key, choice) in self
            .routing
            .account
            .iter()
            .chain(self.routing.api_key.iter())
        {
            if key.is_empty() {
                return Err(Error::config("Empty routing identifier."));
            }
            self.validate_choice(choice)?;
        }
        for c in [
            &self.routing.account_fallback,
            &self.routing.api_key_fallback,
            &self.routing.mcp_fallback,
        ]
        .into_iter()
        .flatten()
        {
            self.validate_choice(c)?;
        }
        for p in &self.providers {
            if p.label().is_empty()
                || p.api_key_env.is_some() && p.api_key_file.is_some()
                || [&p.name, &p.api_key_env, &p.api_key_file]
                    .into_iter()
                    .flatten()
                    .any(|s| s.is_empty())
            {
                return Err(Error::config(
                    "Invalid API Key provider credential sources.",
                ));
            }
            self.validate_choice(&p.proxy)?;
            if let Some(u) = &p.upstream_base_url {
                validate_upstream(u)?;
            }
        }
        Ok(())
    }
    fn validate_choice(&self, c: &Choice) -> Result<()> {
        if c.names().is_empty()
            || c.names()
                .iter()
                .any(|n| n != "none" && !self.proxies.contains_key(n))
        {
            return Err(Error::config(
                "Every route must select an existing proxy or none; lists cannot be empty.",
            ));
        }
        Ok(())
    }
    pub fn endpoint(&self, name: &str) -> &str {
        if name == "none" {
            "none"
        } else {
            &self.proxies[name]
        }
    }
    pub fn canonical_yaml(&self) -> Result<String> {
        #[derive(Serialize)]
        struct Output<'a> {
            listen_port: u16,
            auth_file: &'a str,
            account_auth_file_only: bool,
            request_timeout_seconds: f64,
            base_url: Bases,
            proxies: &'a BTreeMap<String, String>,
            routing: Routing,
        }
        let mut routing = self.routing.clone();
        routing
            .api_key
            .retain(|key, _| crate::url_routing::is_url_selector(key));
        for p in &self.providers {
            if p.api_key_file.is_some()
                || p.upstream_base_url.is_some()
                || (p.name.is_some()
                    && p.api_key_env.is_some()
                    && p.name.as_deref() != Some("openai"))
            {
                return Err(Error::config(
                    "Cannot encode legacy API Key route without losing configuration.",
                ));
            }
            let key = p
                .selector
                .as_deref()
                .or(p.api_key_env.as_deref())
                .or(p.name.as_deref())
                .unwrap();
            if routing
                .api_key
                .insert(key.into(), p.proxy.clone())
                .is_some()
            {
                return Err(Error::config("Duplicate API Key mapping after migration."));
            }
        }
        let mut bases = self.base_url.clone();
        if bases.account.ends_with("/backend-api/codex") {
            bases.account.truncate(bases.account.len() - 6);
        }
        serde_yaml_ng::to_string(&Output {
            listen_port: self.listen_port,
            auth_file: &self.auth_file,
            account_auth_file_only: self.account_auth_file_only,
            request_timeout_seconds: self.request_timeout_seconds,
            base_url: bases,
            proxies: &self.proxies,
            routing,
        })
        .map_err(|_| Error::config("Cannot serialize configuration."))
    }
}
pub fn expand(path: &str) -> PathBuf {
    if path == "~" {
        return dirs::home_dir().unwrap_or_else(|| PathBuf::from("~"));
    }
    if let Some(rest) = path.strip_prefix("~/").or_else(|| path.strip_prefix("~\\")) {
        return dirs::home_dir()
            .unwrap_or_else(|| PathBuf::from("~"))
            .join(rest);
    }
    PathBuf::from(path)
}
pub fn validate_upstream(value: &str) -> Result<Url> {
    let bad = || {
        Error::config(
            "Upstream must be HTTPS with a public hostname and no credentials, query or fragment.",
        )
    };
    let u = Url::parse(value).map_err(|_| bad())?;
    let host = u.host_str().ok_or_else(bad)?;
    if u.scheme() != "https"
        || !u.username().is_empty()
        || u.password().is_some()
        || u.query().is_some()
        || u.fragment().is_some()
        || u.port() == Some(0)
        || !host.contains('.')
        || host.contains(':')
        || host.chars().all(|c| c.is_ascii_digit() || c == '.')
        || host.ends_with('.')
        || ["localhost", "local", "internal", "lan"]
            .iter()
            .any(|s| host == *s || host.ends_with(&format!(".{s}")))
    {
        return Err(bad());
    }
    Ok(u)
}
pub fn unwrap_upstream(value: &str) -> Result<String> {
    if let Ok(u) = Url::parse(value) {
        if u.scheme() == "http"
            && u.host_str() == Some("127.0.0.1")
            && u.port().is_some()
            && u.username().is_empty()
            && u.password().is_none()
            && u.query().is_none()
            && u.fragment().is_none()
            && u.path().starts_with("/https://")
        {
            let inner = &u.path()[1..];
            validate_upstream(inner)?;
            return Ok(inner.into());
        }
    }
    validate_upstream(value)?;
    Ok(value.into())
}
pub fn validate_proxy(value: &str) -> Result<Url> {
    let bad = || {
        Error::config(
            "Invalid proxy URL or credentials; use http/https/socks5://[username:password@]host:port.",
        )
    };
    let u = Url::parse(value).map_err(|_| bad())?;
    // Url normalizes default ports away; inspect the authority to require an explicit port.
    let authority = value
        .split_once("://")
        .map(|(_, v)| v.split('/').next().unwrap_or(""))
        .unwrap_or("");
    let explicit_port = authority
        .rsplit('@')
        .next()
        .unwrap_or("")
        .rsplit_once(':')
        .and_then(|(_, p)| p.parse::<u16>().ok());
    if !matches!(u.scheme(), "http" | "https" | "socks5")
        || u.host_str().is_none()
        || explicit_port.is_none_or(|p| p == 0)
        || u.query().is_some()
        || u.fragment().is_some()
        || !matches!(u.path(), "" | "/")
    {
        return Err(bad());
    }
    if authority.contains('@') {
        let user = percent_encoding::percent_decode_str(u.username())
            .decode_utf8()
            .map_err(|_| bad())?;
        // Url normalizes an explicitly empty password to None. Preserve the raw
        // separator so HTTP user: remains valid while user@ remains invalid.
        let raw_password = authority
            .rsplit_once('@')
            .and_then(|(userinfo, _)| userinfo.split_once(':').map(|(_, password)| password))
            .ok_or_else(bad)?;
        let password = percent_encoding::percent_decode_str(raw_password)
            .decode_utf8()
            .map_err(|_| bad())?;
        if user.is_empty()
            || user.chars().chain(password.chars()).any(|c| c.is_control())
            || (u.scheme() != "socks5" && user.contains(':'))
            || (u.scheme() == "socks5"
                && (!(1..=255).contains(&user.len()) || !(1..=255).contains(&password.len())))
        {
            return Err(bad());
        }
    }
    Ok(u)
}
pub fn redacted_endpoint(value: &str) -> String {
    if value == "none" {
        return value.into();
    }
    // Preserve an explicitly specified default port and omit userinfo entirely.
    match value.split_once("://") {
        Some((scheme, rest)) => format!(
            "{scheme}://{}",
            rest.rsplit('@').next().unwrap_or("").trim_end_matches('/')
        ),
        None => "<invalid-proxy>".into(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rejects_invalid_layouts_and_proxy_choices() {
        let base = "listen_port: 7889\nrequest_timeout_seconds: 3\n";
        for invalid in [
            "unknown: value\n",
            "routing:\n  api_key_fallback: []\n",
            "routing:\n  api_key_fallback: missing\n",
            "routing:\n  unknown: none\n",
            "base_url: {}\nupstream_base_url: https://api.openai.com/v1\n",
            "routing: {}\naccounts: {}\n",
            "routing:\n  account:\n    test: none\n",
            "routing:\n  api_key:\n    TEST:\n      proxy: none\n",
        ] {
            assert!(
                Config::parse(&format!("{base}{invalid}")).is_err(),
                "{invalid}"
            );
        }
        assert!(
            Config::parse(&format!(
                "{base}account_auth_file_only: false\nrouting:\n  account_fallback: none\n"
            ))
            .is_ok()
        );
        assert!(Config::parse("listen_port: 0\nrequest_timeout_seconds: .nan\n").is_err());
    }
    #[test]
    fn proxy_credentials_ports_and_upstream_validation() {
        for p in [
            "http://u:p@localhost:80",
            "https://localhost:443",
            "socks5://u:p@127.0.0.1:1080",
            "http://u:@localhost:8080",
        ] {
            assert!(validate_proxy(p).is_ok(), "{p}");
        }
        for p in [
            "http://localhost",
            "http://localhost:0",
            "http://u@localhost:80",
            "http://u%3Ax:p@localhost:80",
            "socks5://u:@localhost:1080",
            "http://u:p%0A@localhost:80",
            "https://localhost:443/extra",
            "https://localhost:443?q=1",
        ] {
            assert!(validate_proxy(p).is_err(), "{p}");
        }
        for u in [
            "http://api.openai.com/v1",
            "https://127.0.0.1/v1",
            "https://2130706433/v1",
            "https://private.local/v1",
            "https://host.internal/v1",
            "https://[::1]/v1",
            "https://u:p@api.openai.com/v1",
            "https://api.openai.com/v1?q=1",
        ] {
            assert!(validate_upstream(u).is_err(), "{u}");
        }
        assert_eq!(
            unwrap_upstream("http://127.0.0.1:7889/https://provider.invalid/v1").unwrap(),
            "https://provider.invalid/v1"
        );
        assert_eq!(
            redacted_endpoint("https://u:p@proxy.invalid:443"),
            "https://proxy.invalid:443"
        );
    }
    #[test]
    fn canonical_migration_roundtrip_and_loss_refusal() {
        let old = "listen_port: 7889\nrequest_timeout_seconds: 3\nauth_file: ~/auth.json\nupstream_base_url: https://chatgpt.com/backend-api/codex\naccounts:\n  a: none\napi_key_providers:\n  - api_key_env: TEST_KEY\n    proxy: none\n";
        let c = Config::parse(old).unwrap();
        let text = c.canonical_yaml().unwrap();
        let migrated = Config::parse(&text).unwrap();
        assert_eq!(migrated.base_url.account, "https://chatgpt.com/backend-api");
        assert_eq!(migrated.providers[0].label(), "TEST_KEY");
        let lossy = old.replace(
            "api_key_env: TEST_KEY",
            "name: custom\n    api_key_file: ~/key",
        );
        assert!(Config::parse(&lossy).unwrap().canonical_yaml().is_err());
    }
}
