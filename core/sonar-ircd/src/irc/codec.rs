//! Minimal IRC protocol line codec (RFC 2812 subset).

#[derive(Debug, Clone)]
pub struct IrcMessage {
    pub prefix: Option<String>,
    pub command: String,
    pub params: Vec<String>,
}

impl IrcMessage {
    pub fn param(&self, idx: usize) -> Option<&str> {
        self.params.get(idx).map(|s| s.as_str())
    }

    pub fn trailing(&self) -> Option<&str> {
        self.params.last().map(|s| s.as_str())
    }
}

/// Parse one IRC line. Returns None for blank/garbage lines.
pub fn parse_line(input: &str) -> Option<IrcMessage> {
    let input = input.trim_end_matches(|c| (c as u32) == 13 || (c as u32) == 10);
    let mut s = input.trim_start_matches(' ');
    if s.is_empty() {
        return None;
    }

    let prefix = if let Some(rest) = s.strip_prefix(':') {
        let sp = rest.find(' ')?;
        let p = &rest[..sp];
        s = rest[sp..].trim_start_matches(' ');
        Some(p.to_string())
    } else {
        None
    };

    let cmd_end = s.find(' ').unwrap_or(s.len());
    let command = s[..cmd_end].to_ascii_uppercase();
    if command.is_empty() {
        return None;
    }
    s = s[cmd_end..].trim_start_matches(' ');

    let mut params = Vec::new();
    while !s.is_empty() {
        if let Some(trailing) = s.strip_prefix(':') {
            params.push(trailing.to_string());
            break;
        }
        let tok_end = s.find(' ').unwrap_or(s.len());
        params.push(s[..tok_end].to_string());
        s = s[tok_end..].trim_start_matches(' ');
    }

    Some(IrcMessage { prefix, command, params })
}

/// Build a server-originated numeric reply body: :server CODE target :text
/// (no line terminator; the session writer appends CRLF).
pub fn numeric(server: &str, code: &str, target: &str, text: &str) -> String {
    format!(":{server} {code} {target} :{text}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_privmsg_with_trailing() {
        let m = parse_line(":alice!u@h PRIVMSG #general :hello world").unwrap();
        assert_eq!(m.command, "PRIVMSG");
        assert_eq!(m.param(0), Some("#general"));
        assert_eq!(m.trailing(), Some("hello world"));
        assert_eq!(m.prefix.as_deref(), Some("alice!u@h"));
    }

    #[test]
    fn uppercases_command() {
        let m = parse_line("nick foo").unwrap();
        assert_eq!(m.command, "NICK");
        assert_eq!(m.param(0), Some("foo"));
    }

    #[test]
    fn blank_is_none() {
        assert!(parse_line("").is_none());
    }

    #[test]
    fn numeric_body_has_no_terminator() {
        assert_eq!(numeric("srv", "001", "nick", "Welcome"), ":srv 001 nick :Welcome");
    }
}
