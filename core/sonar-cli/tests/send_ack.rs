use std::ffi::OsString;
use std::path::Path;
use std::process::{Command, Output};

use nostr_relay_builder::MockRelay;
use sonar_core::client::SonarClient;
use sonar_core::identity::Identity;

async fn run_cli(args: Vec<OsString>) -> Output {
    tokio::task::spawn_blocking(move || {
        Command::new(env!("CARGO_BIN_EXE_sonar-cli"))
            .args(args)
            .output()
            .expect("run sonar-cli")
    })
    .await
    .expect("join sonar-cli process")
}

fn common_args(home: &Path, relay_url: &str) -> Vec<OsString> {
    vec![
        "--home".into(),
        home.as_os_str().to_owned(),
        "--relay".into(),
        relay_url.into(),
    ]
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn short_lived_send_waits_for_relay_ack_before_process_exit() {
    let relay = MockRelay::run().await.expect("mock relay starts");
    let relay_url = relay.url().await;
    let relay_string = relay_url.to_string();
    let bob = SonarClient::connect_in_memory(Identity::generate(), vec![relay_url])
        .await
        .expect("bob connects");
    bob.publish_key_package().await.expect("bob publishes kp");

    let temp = tempfile::tempdir().expect("tempdir");
    let alice_home = temp.path().join("alice");
    let mut init_args = common_args(&alice_home, &relay_string);
    init_args.push("init".into());
    let init = run_cli(init_args).await;
    assert!(
        init.status.success(),
        "init failed: {}",
        String::from_utf8_lossy(&init.stderr)
    );

    let mut send_args = common_args(&alice_home, &relay_string);
    send_args.extend([
        "send".into(),
        "--to".into(),
        bob.identity().npub().into(),
        "--text".into(),
        "survives process exit".into(),
        "--wait-for-ack".into(),
        "--ack-timeout-secs".into(),
        "5".into(),
    ]);
    let send = run_cli(send_args).await;
    assert!(
        send.status.success(),
        "send failed: {}",
        String::from_utf8_lossy(&send.stderr)
    );
    assert!(
        String::from_utf8_lossy(&send.stdout).contains("\"type\":\"sent\""),
        "send acknowledgement record missing"
    );

    // The sender process is already gone. The message must still be available,
    // proving its background publish reached relay OK before process exit.
    bob.sync().await.expect("bob syncs after sender exits");
    let groups = bob.groups().expect("bob groups");
    assert_eq!(groups.len(), 1);
    let messages = bob.messages(&groups[0].mls_group_id).expect("bob messages");
    assert_eq!(messages.len(), 1);
    assert_eq!(messages[0].content, "survives process exit");
}
