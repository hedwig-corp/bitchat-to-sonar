//! Group invite lifecycle without relay I/O.

use nostr::hashes::sha256::Hash as Sha256Hash;
use nostr::hashes::Hash;
use nostr::nips::nip19::ToBech32;
use nostr::{EventBuilder, Kind, RelayUrl};
use sonar_core::identity::Identity;
use sonar_core::invite_link::{build_join_request_rumor, JOIN_REQUEST_RUMOR_KIND};
use sonar_core::marmot::{Incoming, MarmotEngine};

#[tokio::test]
async fn multi_member_welcomes_wait_for_accept_or_decline() {
    let relay = RelayUrl::parse("wss://relay.example.com").expect("relay url");
    let relays = vec![relay];

    let alice = MarmotEngine::in_memory(Identity::generate());
    let bob = MarmotEngine::in_memory(Identity::generate());
    let charlie = MarmotEngine::in_memory(Identity::generate());

    let bob_kp = bob.key_package_event(relays.clone()).await.expect("bob kp");
    let charlie_kp = charlie
        .key_package_event(relays.clone())
        .await
        .expect("charlie kp");

    let creation = alice
        .create_group("field team", vec![bob_kp, charlie_kp], relays)
        .expect("alice creates group");
    alice
        .merge_pending_commit(&creation.group.mls_group_id)
        .expect("creator merge after welcome delivery");
    assert_eq!(alice.groups().expect("alice groups").len(), 1);

    let (bob_pubkey, bob_welcome) = creation
        .welcomes
        .iter()
        .find(|(pubkey, _)| *pubkey == bob.identity().public_key())
        .cloned()
        .expect("bob welcome");
    let bob_wrapped = alice
        .gift_wrap_welcome(&bob_pubkey, bob_welcome)
        .await
        .expect("wrap bob welcome");
    match bob
        .process_incoming(&bob_wrapped)
        .await
        .expect("bob processes welcome")
    {
        Incoming::GroupInvitePending(group_id) => assert_eq!(group_id, creation.group.mls_group_id),
        other => panic!("expected pending group invite, got {other:?}"),
    }
    assert_eq!(bob.groups().expect("bob active groups").len(), 0);
    let bob_invites = bob.pending_group_invites().expect("bob invites");
    assert_eq!(bob_invites.len(), 1);
    assert_eq!(bob_invites[0].group_name, "field team");
    assert_eq!(bob_invites[0].member_count, 3);

    let accepted_group = bob
        .accept_group_invite(&bob_invites[0].id)
        .expect("bob accepts invite");
    assert_eq!(accepted_group, creation.group.mls_group_id);
    assert_eq!(bob.groups().expect("bob active groups").len(), 1);
    assert!(bob.pending_group_invites().expect("bob invites").is_empty());

    let (charlie_pubkey, charlie_welcome) = creation
        .welcomes
        .iter()
        .find(|(pubkey, _)| *pubkey == charlie.identity().public_key())
        .cloned()
        .expect("charlie welcome");
    let charlie_wrapped = alice
        .gift_wrap_welcome(&charlie_pubkey, charlie_welcome)
        .await
        .expect("wrap charlie welcome");
    match charlie
        .process_incoming(&charlie_wrapped)
        .await
        .expect("charlie processes welcome")
    {
        Incoming::GroupInvitePending(group_id) => assert_eq!(group_id, creation.group.mls_group_id),
        other => panic!("expected pending group invite, got {other:?}"),
    }
    let charlie_invites = charlie
        .pending_group_invites()
        .expect("charlie pending invites");
    assert_eq!(charlie_invites.len(), 1);
    charlie
        .decline_group_invite(&charlie_invites[0].id)
        .expect("charlie declines");
    assert_eq!(charlie.groups().expect("charlie active groups").len(), 0);
    assert!(charlie
        .pending_group_invites()
        .expect("charlie invites after decline")
        .is_empty());
}

#[tokio::test]
async fn unpublished_group_creation_can_be_discarded() {
    let relay = RelayUrl::parse("wss://relay.example.com").expect("relay url");
    let relays = vec![relay];

    let alice = MarmotEngine::in_memory(Identity::generate());
    let bob = MarmotEngine::in_memory(Identity::generate());
    let charlie = MarmotEngine::in_memory(Identity::generate());

    let bob_kp = bob.key_package_event(relays.clone()).await.expect("bob kp");
    let charlie_kp = charlie
        .key_package_event(relays.clone())
        .await
        .expect("charlie kp");

    let creation = alice
        .create_group("field team", vec![bob_kp, charlie_kp], relays)
        .expect("alice creates group");
    let group_id = creation.group.mls_group_id;
    assert_eq!(
        alice.groups().expect("alice groups").len(),
        1,
        "MDK exposes the staged group before the commit is merged"
    );

    alice
        .clear_pending_commit(&group_id)
        .expect("clear pending creation commit");
    alice.delete_group(&group_id).expect("discard staged group");

    assert!(
        alice
            .groups()
            .expect("alice groups after discard")
            .is_empty(),
        "failed welcome delivery must not leave a non-retryable local group"
    );
}

#[tokio::test]
async fn staged_add_member_commit_can_be_rolled_back() {
    let relay = RelayUrl::parse("wss://relay.example.com").expect("relay url");
    let relays = vec![relay];

    let alice = MarmotEngine::in_memory(Identity::generate());
    let bob = MarmotEngine::in_memory(Identity::generate());
    let charlie = MarmotEngine::in_memory(Identity::generate());
    let charlie_pubkey = charlie.identity().public_key();

    let bob_kp = bob.key_package_event(relays.clone()).await.expect("bob kp");
    let creation = alice
        .create_group("alice and bob", vec![bob_kp], relays.clone())
        .expect("alice creates group");
    let group_id = creation.group.mls_group_id;
    alice
        .merge_pending_commit(&group_id)
        .expect("merge initial group");

    let charlie_kp = charlie.key_package_event(relays).await.expect("charlie kp");
    let update = alice
        .add_members(&group_id, vec![charlie_kp])
        .expect("stage add charlie");
    assert_eq!(update.welcomes.len(), 1);
    assert!(
        !alice
            .members(&group_id)
            .expect("members before merge")
            .contains(&charlie_pubkey),
        "staged add-member state stays pending until commit merge"
    );

    alice
        .clear_pending_commit(&group_id)
        .expect("clear staged add-member commit");

    assert!(
        !alice
            .members(&group_id)
            .expect("members after rollback")
            .contains(&charlie_pubkey),
        "failed welcome delivery must not leave the undelivered invitee as a local member"
    );
}

#[tokio::test]
async fn partially_published_group_creation_can_still_be_merged() {
    let relay = RelayUrl::parse("wss://relay.example.com").expect("relay url");
    let relays = vec![relay];

    let alice = MarmotEngine::in_memory(Identity::generate());
    let bob = MarmotEngine::in_memory(Identity::generate());
    let charlie = MarmotEngine::in_memory(Identity::generate());

    let bob_kp = bob.key_package_event(relays.clone()).await.expect("bob kp");
    let charlie_kp = charlie
        .key_package_event(relays.clone())
        .await
        .expect("charlie kp");

    let creation = alice
        .create_group("field team", vec![bob_kp, charlie_kp], relays)
        .expect("alice creates group");
    let group_id = creation.group.mls_group_id;

    assert_eq!(
        creation.welcomes.len(),
        2,
        "test needs multiple welcomes so one can be considered already published"
    );

    alice
        .merge_pending_commit(&group_id)
        .expect("partial welcome publish keeps creator pending commit mergeable");

    let members = alice.members(&group_id).expect("members after merge");
    assert!(members.contains(&bob.identity().public_key()));
    assert!(members.contains(&charlie.identity().public_key()));
}

#[tokio::test]
async fn published_add_member_commit_remains_mergeable_after_welcome_failure() {
    let relay = RelayUrl::parse("wss://relay.example.com").expect("relay url");
    let relays = vec![relay];

    let alice = MarmotEngine::in_memory(Identity::generate());
    let bob = MarmotEngine::in_memory(Identity::generate());
    let charlie = MarmotEngine::in_memory(Identity::generate());
    let charlie_pubkey = charlie.identity().public_key();

    let bob_kp = bob.key_package_event(relays.clone()).await.expect("bob kp");
    let creation = alice
        .create_group("alice and bob", vec![bob_kp], relays.clone())
        .expect("alice creates group");
    let group_id = creation.group.mls_group_id;
    alice
        .merge_pending_commit(&group_id)
        .expect("merge initial group");

    let charlie_kp = charlie.key_package_event(relays).await.expect("charlie kp");
    let update = alice
        .add_members(&group_id, vec![charlie_kp])
        .expect("stage add charlie");
    assert_eq!(update.welcomes.len(), 1);
    assert!(
        !alice
            .members(&group_id)
            .expect("members before merge")
            .contains(&charlie_pubkey),
        "staged add-member state stays pending until commit merge"
    );

    alice
        .merge_pending_commit(&group_id)
        .expect("published add-member commit remains mergeable after welcome retry");

    assert!(
        alice
            .members(&group_id)
            .expect("members after merge")
            .contains(&charlie_pubkey),
        "kept pending commit can converge after welcome delivery is recovered"
    );
}

/// R: an invite link is meant to be forwarded, so holding one proves nothing
/// about who is asking to join. The only authenticated identity in a NIP-59
/// envelope is the seal author; `requester_npub` sits in the rumor body, which
/// the sender writes. Without binding the request to the seal, anyone holding a
/// link can post join requests naming arbitrary third parties, and the admin's
/// approval UI, the entire access control for invite links, shows the spoofed
/// name.
#[tokio::test]
async fn join_request_naming_a_third_party_is_rejected() {
    let secret = b"invite-secret";

    let admin = MarmotEngine::in_memory(Identity::generate());
    let mallory = MarmotEngine::in_memory(Identity::generate());
    let victim = Identity::generate();
    // A real group the admin owns, so the request is exercised against a group
    // id the engine actually holds rather than a synthetic one.
    let relays = vec![RelayUrl::parse("wss://relay.example.com").expect("relay url")];
    let member = MarmotEngine::in_memory(Identity::generate());
    let member_kp = member.key_package_event(relays.clone()).await.expect("member kp");
    let group_id = admin
        .create_group("crew", vec![member_kp], relays)
        .expect("admin creates group")
        .group
        .mls_group_id;

    // Mallory seals honestly (rumor.pubkey == seal author, so the envelope
    // itself is valid) but writes the victim's npub into the request body.
    let content = serde_json::json!({
        "group_id": hex::encode(group_id.as_slice()),
        "invite_secret_hash": hex::encode(Sha256Hash::hash(secret).to_byte_array()),
        "requester_npub": victim.public_key().to_bech32().expect("victim npub"),
        "key_package_event_id": None::<String>,
    });
    let spoofed = EventBuilder::new(Kind::Custom(JOIN_REQUEST_RUMOR_KIND), content.to_string())
        .build(mallory.identity().public_key());

    let wrapped = mallory
        .gift_wrap_rumor(&admin.identity().public_key(), spoofed)
        .await
        .expect("mallory wraps spoofed join request");

    match admin
        .process_incoming(&wrapped)
        .await
        .expect("admin processes join request")
    {
        Incoming::JoinRequest(req) => panic!(
            "spoofed join request surfaced to admin as {}",
            req.requester.to_bech32().expect("npub")
        ),
        Incoming::None => {}
        other => panic!("expected the spoofed request to be dropped, got {other:?}"),
    }
}

/// The honest path must still work: a requester naming itself is accepted, and
/// the surfaced identity is the seal author.
#[tokio::test]
async fn join_request_naming_itself_is_accepted_with_seal_identity() {
    let secret = b"invite-secret";

    let admin = MarmotEngine::in_memory(Identity::generate());
    let joiner = MarmotEngine::in_memory(Identity::generate());
    let joiner_pubkey = joiner.identity().public_key();
    // A real group the admin owns, so the request is exercised against a group
    // id the engine actually holds rather than a synthetic one.
    let relays = vec![RelayUrl::parse("wss://relay.example.com").expect("relay url")];
    let member = MarmotEngine::in_memory(Identity::generate());
    let member_kp = member.key_package_event(relays.clone()).await.expect("member kp");
    let group_id = admin
        .create_group("crew", vec![member_kp], relays)
        .expect("admin creates group")
        .group
        .mls_group_id;

    let rumor = build_join_request_rumor(&group_id, secret, &joiner_pubkey, None);
    let wrapped = joiner
        .gift_wrap_rumor(&admin.identity().public_key(), rumor)
        .await
        .expect("joiner wraps join request");

    match admin
        .process_incoming(&wrapped)
        .await
        .expect("admin processes join request")
    {
        Incoming::JoinRequest(req) => {
            assert_eq!(
                req.requester, joiner_pubkey,
                "surfaced requester must be the seal author"
            );
            assert_eq!(req.group_id, group_id);
        }
        other => panic!("expected an accepted join request, got {other:?}"),
    }
}

/// R: neither `Error::Json` nor `Error::InvalidInput` is terminal per
/// `is_terminal_marmot_processing_error`, so returning `Err` for a malformed
/// join request skips `mark_sync_event_processed` and the event is refetched
/// and re-fails on every sync forever. One junk rumor from a stranger is enough
/// to pin the sync cursor, so every malformed-body exit must be `Incoming::None`.
#[tokio::test]
async fn malformed_join_requests_are_discarded_not_retried_forever() {
    let admin = MarmotEngine::in_memory(Identity::generate());
    let sender = MarmotEngine::in_memory(Identity::generate());
    let sender_npub = sender
        .identity()
        .public_key()
        .to_bech32()
        .expect("sender npub");

    let bodies = [
        ("not json at all", "{".to_string()),
        ("missing fields", "{}".to_string()),
        (
            "group id not hex",
            serde_json::json!({
                "group_id": "zzzz",
                "invite_secret_hash": hex::encode([0u8; 32]),
                "requester_npub": sender_npub,
                "key_package_event_id": None::<String>,
            })
            .to_string(),
        ),
        (
            "secret hash not hex",
            serde_json::json!({
                "group_id": hex::encode([7u8; 32]),
                "invite_secret_hash": "nothex",
                "requester_npub": sender_npub,
                "key_package_event_id": None::<String>,
            })
            .to_string(),
        ),
        (
            "requester npub undecodable",
            serde_json::json!({
                "group_id": hex::encode([7u8; 32]),
                "invite_secret_hash": hex::encode([0u8; 32]),
                "requester_npub": "npub1notarealkey",
                "key_package_event_id": None::<String>,
            })
            .to_string(),
        ),
    ];

    for (label, content) in bodies {
        let rumor = EventBuilder::new(Kind::Custom(JOIN_REQUEST_RUMOR_KIND), content)
            .build(sender.identity().public_key());
        let wrapped = sender
            .gift_wrap_rumor(&admin.identity().public_key(), rumor)
            .await
            .expect("wrap malformed join request");

        match admin.process_incoming(&wrapped).await {
            Ok(Incoming::None) => {}
            Ok(other) => panic!("{label}: expected the request to be discarded, got {other:?}"),
            Err(err) => panic!(
                "{label}: returned Err({err}), which is non-terminal and re-drives the sync \
                 cursor on every sync"
            ),
        }
    }
}

/// An MLS group id is variable-length (`GroupId` wraps `VLBytes`), so an
/// odd-length one parses rather than being rejected here, and `from_slice`
/// cannot panic on it. Authorization is downstream: `store_join_request`
/// rejects any group id whose invite secret does not validate. What must hold
/// at this layer is that no such input panics or returns a non-terminal `Err`
/// that would pin the sync cursor.
#[tokio::test]
async fn odd_length_group_id_neither_panics_nor_pins_the_cursor() {
    let admin = MarmotEngine::in_memory(Identity::generate());
    let sender = MarmotEngine::in_memory(Identity::generate());
    let sender_npub = sender
        .identity()
        .public_key()
        .to_bech32()
        .expect("sender npub");

    for (label, group_id_hex) in [
        ("empty", String::new()),
        ("five bytes", hex::encode([7u8; 5])),
        ("sixty four bytes", hex::encode([7u8; 64])),
    ] {
        let content = serde_json::json!({
            "group_id": group_id_hex,
            "invite_secret_hash": hex::encode([0u8; 32]),
            "requester_npub": sender_npub,
            "key_package_event_id": None::<String>,
        })
        .to_string();
        let rumor = EventBuilder::new(Kind::Custom(JOIN_REQUEST_RUMOR_KIND), content)
            .build(sender.identity().public_key());
        let wrapped = sender
            .gift_wrap_rumor(&admin.identity().public_key(), rumor)
            .await
            .expect("wrap join request");

        match admin.process_incoming(&wrapped).await {
            Ok(_) => {}
            Err(err) => panic!(
                "{label}: returned Err({err}), which is non-terminal and re-drives the sync cursor"
            ),
        }
    }
}
