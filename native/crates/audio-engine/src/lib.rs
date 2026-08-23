//! Opus 20 ms capture/play + jitter. Implemented in PR4.

pub fn crate_name() -> &'static str {
    "audio-engine"
}

#[cfg(test)]
mod tests {
    #[test]
    fn named() {
        assert_eq!(super::crate_name(), "audio-engine");
    }
}
