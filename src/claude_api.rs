//! Explicit, configured third-party Claude API upstreams.

pub(crate) fn explicit_target(target: &str) -> Option<&str> {
    let target = ["/anthropic", "/claude"]
        .into_iter()
        .find_map(|prefix| {
            target
                .strip_prefix(prefix)
                .filter(|rest| rest.starts_with('/'))
        })
        .unwrap_or(target);
    target.starts_with("/https://").then_some(target)
}

pub(crate) use crate::url_routing::validate_upstream as validate_api_upstream;

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn public_ip_routes_reject_private_and_malformed_destinations() {
        assert!(validate_api_upstream("https://182.92.106.196:6060").is_ok());
        assert!(validate_api_upstream("https://gateway.invalid/anthropic").is_ok());
        for base in [
            "http://182.92.106.196:6060",
            "https://127.0.0.1",
            "https://2130706433",
            "https://10.0.0.1",
            "https://169.254.169.254",
            "https://100.64.0.1",
            "https://198.18.0.1",
            "https://224.0.0.1",
            "https://192.0.2.1",
            "https://user:secret@182.92.106.196:6060",
            "https://182.92.106.196:6060?q=1",
        ] {
            assert!(validate_api_upstream(base).is_err(), "{base}");
        }
    }
}
