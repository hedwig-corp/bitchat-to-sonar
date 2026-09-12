//! Process-level pin that the migrate CLI spend gates fire before any wallet
//! open: no `$SONAR_NSEC`, no Breez store, no mint connect.

use std::process::Command;

fn bin() -> Command {
    Command::new(env!("CARGO_BIN_EXE_sonar-migrate-cli"))
}

fn combined(output: &std::process::Output) -> String {
    let mut text = String::from_utf8_lossy(&output.stderr).into_owned();
    text.push_str(&String::from_utf8_lossy(&output.stdout));
    text
}

#[test]
fn migrate_without_custody_consent_refuses_without_nsec() {
    let output = bin()
        .args(["migrate", "--max-fee-sats", "50"])
        .env_remove("SONAR_NSEC")
        .env_remove("BREEZ_API_KEY")
        .output()
        .expect("spawn sonar-migrate-cli");
    assert!(
        !output.status.success(),
        "migrate without consent must fail"
    );
    let text = combined(&output);
    assert!(
        text.contains("accept-custody-change"),
        "unexpected refusal: {text}"
    );
    assert!(
        !text.contains("SONAR_NSEC"),
        "consent must fail before secrets are read: {text}"
    );
}

#[test]
fn migrate_with_custody_consent_reaches_nsec_gate() {
    let output = bin()
        .args([
            "--mint",
            "https://mint.hedwig.sh",
            "migrate",
            "--max-fee-sats",
            "50",
            "--accept-custody-change",
        ])
        .env_remove("SONAR_NSEC")
        .env_remove("BREEZ_API_KEY")
        .output()
        .expect("spawn sonar-migrate-cli");
    assert!(!output.status.success());
    let text = combined(&output);
    assert!(
        text.contains("SONAR_NSEC"),
        "consented migrate must proceed to the secret gate: {text}"
    );
    assert!(
        !text.contains("accept-custody-change"),
        "consent was given: {text}"
    );
}

#[test]
fn sim_fund_without_source_mint_refuses_without_nsec() {
    let output = bin()
        .args(["sim-fund", "--amount-sats", "1000"])
        .env_remove("SONAR_NSEC")
        .env_remove("BREEZ_API_KEY")
        .output()
        .expect("spawn sonar-migrate-cli");
    assert!(!output.status.success());
    let text = combined(&output);
    assert!(
        text.contains("sim-fund requires --source-mint"),
        "unexpected refusal: {text}"
    );
    assert!(
        !text.contains("SONAR_NSEC"),
        "sim-fund must not open Breez: {text}"
    );
}
