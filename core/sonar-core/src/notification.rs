use crate::call::signaling::CallControl;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum NotificationKind {
    Message,
    Payment,
    Call,
    Invite,
    Mention,
    Geohash,
    Network,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct NotificationRenderInput {
    pub enabled: bool,
    pub kind_hint: Option<NotificationKind>,
    pub conversation_title: Option<String>,
    pub sender_name: Option<String>,
    pub group_name: Option<String>,
    pub content_preview: Option<String>,
    pub unread_count: u64,
    pub show_names: bool,
    pub show_preview: bool,
    pub show_payment_amount: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct NotificationEnvelope {
    pub kind: NotificationKind,
    pub title: String,
    pub body: String,
    pub payment_sats: Option<u64>,
}

pub fn classify_content(content: &str) -> NotificationKind {
    if CallControl::parse(content).is_some() {
        return NotificationKind::Call;
    }
    if payment_amount_sats(content).is_some() {
        return NotificationKind::Payment;
    }
    NotificationKind::Message
}

pub fn payment_amount_sats(content: &str) -> Option<u64> {
    let mut parts = content.split('|');
    if parts.next()? != "⚡PAY" {
        return None;
    }
    if parts.next()? != "1" {
        return None;
    }
    let id = parts.next()?;
    if !valid_payment_id(id) {
        return None;
    }
    let sats = parts.next()?.parse::<u64>().ok()?;
    if sats == 0 || parts.next().is_some() {
        return None;
    }
    Some(sats)
}

pub fn render_notification(input: NotificationRenderInput) -> Option<NotificationEnvelope> {
    if !input.enabled {
        return None;
    }
    let content = input.content_preview.as_deref().unwrap_or("");
    let kind = input.kind_hint.unwrap_or_else(|| classify_content(content));
    let payment_sats = payment_amount_sats(content);
    let label = visible_label(&input);
    let group = visible_group(&input);
    let title = title(kind, label.as_deref(), group.as_deref());
    let body = body(
        kind,
        &input,
        payment_sats,
        label.as_deref(),
        group.as_deref(),
    );
    Some(NotificationEnvelope {
        kind,
        title,
        body,
        payment_sats,
    })
}

fn title(kind: NotificationKind, label: Option<&str>, group: Option<&str>) -> String {
    match kind {
        NotificationKind::Message => match (label, group) {
            (Some(sender), Some(group)) => format!("{sender} in {group}"),
            (Some(sender), None) => sender.to_string(),
            (None, Some(group)) => group.to_string(),
            (None, None) => "New Sonar message".to_string(),
        },
        NotificationKind::Payment => match label {
            Some(sender) => format!("Payment from {sender}"),
            None => "Payment received".to_string(),
        },
        NotificationKind::Call => match label {
            Some(sender) => format!("Incoming call from {sender}"),
            None => "Incoming Sonar call".to_string(),
        },
        NotificationKind::Invite => match label {
            Some(sender) => format!("Invite from {sender}"),
            None => "New Sonar invite".to_string(),
        },
        NotificationKind::Mention => match label {
            Some(sender) => format!("{sender} mentioned you"),
            None => "You were mentioned".to_string(),
        },
        NotificationKind::Geohash => group
            .or(label)
            .map(ToString::to_string)
            .unwrap_or_else(|| "New channel activity".to_string()),
        NotificationKind::Network => "People nearby on Sonar".to_string(),
    }
}

fn body(
    kind: NotificationKind,
    input: &NotificationRenderInput,
    payment_sats: Option<u64>,
    label: Option<&str>,
    group: Option<&str>,
) -> String {
    match kind {
        NotificationKind::Message | NotificationKind::Mention | NotificationKind::Geohash => {
            if input.show_preview {
                if let Some(preview) = sanitize_preview(input.content_preview.as_deref()) {
                    return preview;
                }
            }
            if input.unread_count > 1 {
                return format!("{} unread messages.", input.unread_count);
            }
            match kind {
                NotificationKind::Geohash => "Open Sonar to view the channel.".to_string(),
                _ => "Open Sonar to read it.".to_string(),
            }
        }
        NotificationKind::Payment => {
            let amount = payment_sats
                .filter(|_| input.show_payment_amount)
                .map(format_sats);
            match (amount, label, group) {
                (Some(amount), Some(sender), Some(group)) => {
                    format!("{amount} received from {sender} in {group}.")
                }
                (Some(amount), Some(sender), None) => {
                    format!("{amount} received from {sender}.")
                }
                (Some(amount), None, Some(group)) => format!("{amount} received in {group}."),
                (Some(amount), None, None) => format!("{amount} received."),
                (None, _, _) => "Open Sonar to view the payment.".to_string(),
            }
        }
        NotificationKind::Call => "Tap to answer.".to_string(),
        NotificationKind::Invite => match group {
            Some(group) => format!("Open Sonar to review the invite to {group}."),
            None => "Open Sonar to review the invite.".to_string(),
        },
        NotificationKind::Network => "Open Sonar to see who is nearby.".to_string(),
    }
}

fn visible_label(input: &NotificationRenderInput) -> Option<String> {
    if !input.show_names {
        return None;
    }
    nonblank(input.sender_name.as_deref()).or_else(|| nonblank(input.conversation_title.as_deref()))
}

fn visible_group(input: &NotificationRenderInput) -> Option<String> {
    if !input.show_names {
        return None;
    }
    let group = nonblank(input.group_name.as_deref());
    let sender = nonblank(input.sender_name.as_deref());
    match (group, sender) {
        (Some(group), Some(sender)) if group == sender => None,
        (Some(group), _) => Some(group),
        _ => None,
    }
}

fn nonblank(value: Option<&str>) -> Option<String> {
    let trimmed = value?.trim();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed.to_string())
    }
}

fn sanitize_preview(value: Option<&str>) -> Option<String> {
    let collapsed = value?.split_whitespace().collect::<Vec<_>>().join(" ");
    if collapsed.is_empty() {
        return None;
    }
    if collapsed.chars().count() <= 80 {
        return Some(collapsed);
    }
    let mut out: String = collapsed.chars().take(80).collect();
    out.push_str("...");
    Some(out)
}

fn format_sats(sats: u64) -> String {
    let raw = sats.to_string();
    let mut out = String::new();
    for (i, ch) in raw.chars().rev().enumerate() {
        if i > 0 && i % 3 == 0 {
            out.push(',');
        }
        out.push(ch);
    }
    let grouped: String = out.chars().rev().collect();
    format!("{grouped} sats")
}

fn valid_payment_id(id: &str) -> bool {
    !id.is_empty() && id.len() <= 64 && id.bytes().all(|b| b.is_ascii_hexdigit() || b == b'-')
}

#[cfg(test)]
mod tests {
    use super::*;

    fn input(content: &str) -> NotificationRenderInput {
        NotificationRenderInput {
            enabled: true,
            kind_hint: None,
            conversation_title: None,
            sender_name: Some("Alice".to_string()),
            group_name: None,
            content_preview: Some(content.to_string()),
            unread_count: 1,
            show_names: true,
            show_preview: false,
            show_payment_amount: true,
        }
    }

    #[test]
    fn classifies_call_payment_and_message() {
        assert_eq!(
            classify_content("☎CALL|1|OFFER|c|voice|addr|1"),
            NotificationKind::Call
        );
        assert_eq!(
            classify_content("⚡PAY|1|abc-123|2100"),
            NotificationKind::Payment
        );
        assert_eq!(classify_content("hello"), NotificationKind::Message);
    }

    #[test]
    fn message_title_shows_sender_and_group() {
        let mut req = input("secret text");
        req.group_name = Some("Signal Room".to_string());
        let n = render_notification(req).unwrap();
        assert_eq!(n.title, "Alice in Signal Room");
        assert_eq!(n.body, "Open Sonar to read it.");
    }

    #[test]
    fn preview_still_requires_opt_in() {
        let mut req = input("hello\nthere");
        req.show_preview = true;
        let n = render_notification(req).unwrap();
        assert_eq!(n.title, "Alice");
        assert_eq!(n.body, "hello there");
    }

    #[test]
    fn payment_shows_amount_by_default() {
        let n = render_notification(input("⚡PAY|1|abc-123|21000")).unwrap();
        assert_eq!(n.title, "Payment from Alice");
        assert_eq!(n.body, "21,000 sats received from Alice.");
        assert_eq!(n.payment_sats, Some(21_000));
    }

    #[test]
    fn disabled_notifications_return_none() {
        let mut req = input("hello");
        req.enabled = false;
        assert!(render_notification(req).is_none());
    }
}
