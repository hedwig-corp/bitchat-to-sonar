//! Group invite lifecycle without relay I/O.

use nostr::hashes::sha256::Hash as Sha256Hash;
use nostr::hashes::Hash;
use nostr::nips::nip19::ToBech32;
use nostr::{EventBuilder, Kind, RelayUrl};
use sonar_core::identity::Identity;
use sonar_core::invite_link::{build_join_request_rumor, JOIN_REQUEST_RUMOR_KIND};
use sonar_core::marmot::{
    Incoming, MarmotEngine, PENDING_INVITE_CAP, UNKNOWN_DM_AUTOACCEPT_MAX,
};

#[tokio::test]
async fn multi_member_welcomes_wait_for_accept_or_decline() {
    let relay = RelayUrl::parse("wss://relay.example.com").expect("relay url");
    let relays = vec![relay];

    let alice = MarmotEngine::in_memory(Identity::generate());
    let bob = MarmotEngine::in_memory(Identity::generate());
    let charlie = MarmotEngine::in_memory(Identity::generate());

    let bob_kp = bob.key_package_event(relays.clone()).expect("bob kp");
    let charlie_kp = charlie
        .key_package_event(relays.clone())
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

    let bob_kp = bob.key_package_event(relays.clone()).expect("bob kp");
    let charlie_kp = charlie
        .key_package_event(relays.clone())
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

    let bob_kp = bob.key_package_event(relays.clone()).expect("bob kp");
    let creation = alice
        .create_group("alice and bob", vec![bob_kp], relays.clone())
        .expect("alice creates group");
    let group_id = creation.group.mls_group_id;
    alice
        .merge_pending_commit(&group_id)
        .expect("merge initial group");

    let charlie_kp = charlie.key_package_event(relays).expect("charlie kp");
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

    let bob_kp = bob.key_package_event(relays.clone()).expect("bob kp");
    let charlie_kp = charlie
        .key_package_event(relays.clone())
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

    let bob_kp = bob.key_package_event(relays.clone()).expect("bob kp");
    let creation = alice
        .create_group("alice and bob", vec![bob_kp], relays.clone())
        .expect("alice creates group");
    let group_id = creation.group.mls_group_id;
    alice
        .merge_pending_commit(&group_id)
        .expect("merge initial group");

    let charlie_kp = charlie.key_package_event(relays).expect("charlie kp");
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
    let member_kp = member.key_package_event(relays.clone()).expect("member kp");
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
    let member_kp = member.key_package_event(relays.clone()).expect("member kp");
    let group_id = admin
        .create_group("crew", vec![member_kp], relays)
        .expect("admin creates group")
        .group
        .mls_group_id;

    let rumor = build_join_request_rumor(&group_id, secret, &joiner_pubkey, None, None);
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

/// #419 helper: a fresh stranger identity creates a 2-member group with
/// `receiver`'s key package and returns (stranger, gift-wrapped welcome).
async fn stranger_dm_welcome(receiver: &MarmotEngine) -> (MarmotEngine, nostr::Event) {
    let relay = RelayUrl::parse("wss://relay.example.com").expect("relay url");
    let stranger = MarmotEngine::in_memory(Identity::generate());
    let kp = receiver
        .key_package_event(vec![relay.clone()])
        .expect("receiver key package");
    let creation = stranger
        .create_group("dm", vec![kp], vec![relay])
        .expect("stranger creates 2-member group");
    let (pk, welcome) = creation.welcomes[0].clone();
    let wrapped = stranger
        .gift_wrap_welcome(&pk, welcome)
        .await
        .expect("wrap welcome");
    (stranger, wrapped)
}

/// #419: our KeyPackage is public, so anyone can gift-wrap a 2-member
/// welcome. Unconditional auto-accept meant unbounded silent MLS groups and
/// chat rows. Unknown senders are rate limited; overflow surfaces as a
/// pending invite the user can still accept.
#[tokio::test]
async fn unknown_sender_dm_welcomes_rate_limit_to_pending() {
    let bob = MarmotEngine::in_memory(Identity::generate());

    // The first strangers inside the budget still auto-accept (compatibility
    // with the normal first-contact DM flow).
    for i in 0..UNKNOWN_DM_AUTOACCEPT_MAX {
        let (_stranger, wrapped) = stranger_dm_welcome(&bob).await;
        match bob.process_incoming(&wrapped).await.expect("process") {
            Incoming::GroupUpdated(_) => {}
            other => panic!("welcome {i} should auto-accept, got {other:?}"),
        }
    }
    assert_eq!(bob.groups().expect("groups").len(), UNKNOWN_DM_AUTOACCEPT_MAX);

    // The next one inside the window routes to the pending accept/decline UI —
    // visible, bounded, and still acceptable by the user.
    let (_stranger, wrapped) = stranger_dm_welcome(&bob).await;
    let pending_group = match bob.process_incoming(&wrapped).await.expect("process") {
        Incoming::GroupInvitePending(group_id) => group_id,
        other => panic!("welcome past the limit must be pending, got {other:?}"),
    };
    assert_eq!(
        bob.groups().expect("groups").len(),
        UNKNOWN_DM_AUTOACCEPT_MAX,
        "no silent group past the limit"
    );
    let invites = bob.pending_group_invites().expect("invites");
    assert_eq!(invites.len(), 1);
    let accepted = bob
        .accept_group_invite(&invites[0].id)
        .expect("user can still accept a rate-limited welcome");
    assert_eq!(accepted, pending_group);
    assert_eq!(
        bob.groups().expect("groups").len(),
        UNKNOWN_DM_AUTOACCEPT_MAX + 1
    );
}

/// #419: a welcomer we already share an active group with is a known peer —
/// their welcomes auto-accept even with the unknown-sender budget exhausted
/// (re-invites, key rotation, linked second device).
#[tokio::test]
async fn known_sender_dm_welcome_auto_accepts_past_the_limit() {
    let relay = RelayUrl::parse("wss://relay.example.com").expect("relay url");
    let bob = MarmotEngine::in_memory(Identity::generate());
    let alice = MarmotEngine::in_memory(Identity::generate());

    // First contact from Alice consumes one unknown-sender slot and gives
    // Bob a shared active group with her.
    let kp = bob
        .key_package_event(vec![relay.clone()])
        .expect("bob key package");
    let creation = alice
        .create_group("dm", vec![kp], vec![relay.clone()])
        .expect("alice creates dm");
    let (pk, welcome) = creation.welcomes[0].clone();
    let wrapped = alice.gift_wrap_welcome(&pk, welcome).await.expect("wrap");
    match bob.process_incoming(&wrapped).await.expect("process") {
        Incoming::GroupUpdated(_) => {}
        other => panic!("first contact should auto-accept, got {other:?}"),
    }

    // Strangers exhaust the remaining budget.
    let mut saw_pending = false;
    for _ in 0..UNKNOWN_DM_AUTOACCEPT_MAX {
        let (_stranger, wrapped) = stranger_dm_welcome(&bob).await;
        if let Incoming::GroupInvitePending(_) =
            bob.process_incoming(&wrapped).await.expect("process")
        {
            saw_pending = true;
        }
    }
    assert!(saw_pending, "budget must be exhausted by now");

    // Alice again (new group, e.g. after a reset): known peer, still instant.
    let kp = bob
        .key_package_event(vec![relay.clone()])
        .expect("bob key package 2");
    let creation = alice
        .create_group("dm again", vec![kp], vec![relay])
        .expect("alice creates dm again");
    let (pk, welcome) = creation.welcomes[0].clone();
    let wrapped = alice.gift_wrap_welcome(&pk, welcome).await.expect("wrap");
    match bob.process_incoming(&wrapped).await.expect("process") {
        Incoming::GroupUpdated(_) => {}
        other => panic!("known-sender welcome must bypass the limit, got {other:?}"),
    }
}

/// #419 defense-in-depth layering: NIP-59 unwrapping rejects a mismatched
/// seal (`SenderMismatch`) before any MLS processing, so this test pins THAT
/// layer — the wire path. The engine's own `seal_sender == welcomer` check is
/// unreachable from the wire in nostr 0.44 (MDK derives `welcomer` from the
/// rumor author, which NIP-59 forces equal to the seal author); it exists as
/// a cheap, MDK-version-independent backstop and is exercised nowhere else.
#[tokio::test]
async fn welcome_sealed_by_a_third_party_is_rejected() {
    let relay = RelayUrl::parse("wss://relay.example.com").expect("relay url");
    let bob = MarmotEngine::in_memory(Identity::generate());
    let alice = MarmotEngine::in_memory(Identity::generate());
    let mallory = MarmotEngine::in_memory(Identity::generate());

    let kp = bob
        .key_package_event(vec![relay.clone()])
        .expect("bob key package");
    let creation = alice
        .create_group("dm", vec![kp], vec![relay])
        .expect("alice creates dm");
    let (_pk, welcome_rumor) = creation.welcomes[0].clone();

    // Mallory re-seals Alice's welcome rumor under her own key.
    let wrapped = mallory
        .gift_wrap_rumor(&bob.identity().public_key(), welcome_rumor)
        .await
        .expect("mallory wraps alice's welcome");
    assert!(
        bob.process_incoming(&wrapped).await.is_err(),
        "a third-party-sealed welcome must be rejected at unwrap"
    );
    assert_eq!(
        bob.groups().expect("groups").len(),
        0,
        "no group is silently created for a mismatched seal"
    );
    assert_eq!(
        bob.pending_group_invites().expect("invites").len(),
        0,
        "and nothing is parked as pending either"
    );
}


/// #419: past the parked-invite ceiling the welcome is DROPPED (declined),
/// not parked — otherwise the flood just moves from silent groups into an
/// unbounded invite list pinned above every real conversation. The ceiling
/// counts invites of EVERY size: a DM-only ceiling would leave a spammer
/// minting 3-member groups an open door (review round 2).
#[tokio::test]
async fn dm_invite_flood_is_capped() {
    let bob = MarmotEngine::in_memory(Identity::generate());

    // Exhaust the auto-accept budget…
    for _ in 0..UNKNOWN_DM_AUTOACCEPT_MAX {
        let (_s, wrapped) = stranger_dm_welcome(&bob).await;
        match bob.process_incoming(&wrapped).await.expect("process") {
            Incoming::GroupUpdated(_) => {}
            other => panic!("expected auto-accept, got {other:?}"),
        }
    }
    // …then park up to the ceiling…
    for i in 0..PENDING_INVITE_CAP {
        let (_s, wrapped) = stranger_dm_welcome(&bob).await;
        match bob.process_incoming(&wrapped).await.expect("process") {
            Incoming::GroupInvitePending(_) => {}
            other => panic!("welcome {i} should park, got {other:?}"),
        }
    }
    assert_eq!(
        bob.pending_group_invites().expect("invites").len(),
        PENDING_INVITE_CAP
    );
    // …past it, welcomes are declined outright and stay invisible.
    let (_s, wrapped) = stranger_dm_welcome(&bob).await;
    match bob.process_incoming(&wrapped).await.expect("process") {
        Incoming::None => {}
        other => panic!("past the cap the welcome must be dropped, got {other:?}"),
    }
    assert_eq!(
        bob.pending_group_invites().expect("invites").len(),
        PENDING_INVITE_CAP,
        "the invite list must not grow past the ceiling"
    );
    assert_eq!(
        bob.groups().expect("groups").len(),
        UNKNOWN_DM_AUTOACCEPT_MAX,
        "and no group is silently created either"
    );
}

/// #419 review round 2: the persisted budget must be wired at the REAL call
/// site (`MarmotEngine::persistent`), not just testable through the helper.
/// The first cut constructed the budget with `in_memory()` there, so every
/// reopen — i.e. every iOS NSE push wake — handed out a fresh budget while
/// the helper-level test stayed green. This is the R-001 shape the ledger
/// warns about, so it is pinned through a real engine reopen.
#[tokio::test]
async fn autoaccept_budget_survives_a_persistent_engine_reopen() {
    let dir = tempfile::tempdir().expect("tempdir");
    let db_path = dir.path().join("marmot.sqlite");
    let key = [0x42u8; 32];
    let identity = Identity::generate();

    {
        let bob = MarmotEngine::persistent(identity.clone(), &db_path, key).expect("open");
        for _ in 0..UNKNOWN_DM_AUTOACCEPT_MAX {
            let (_s, wrapped) = stranger_dm_welcome(&bob).await;
            match bob.process_incoming(&wrapped).await.expect("process") {
                Incoming::GroupUpdated(_) => {}
                other => panic!("expected auto-accept, got {other:?}"),
            }
        }
    }

    // A fresh process (NSE wake) reopens the same DB: the window must carry
    // over, so the next unknown sender parks instead of auto-accepting.
    let bob = MarmotEngine::persistent(identity, &db_path, key).expect("reopen");
    let (_s, wrapped) = stranger_dm_welcome(&bob).await;
    match bob.process_incoming(&wrapped).await.expect("process") {
        Incoming::GroupInvitePending(_) => {}
        other => panic!("a reopened engine must inherit the exhausted window, got {other:?}"),
    }
    assert_eq!(
        bob.groups().expect("groups").len(),
        UNKNOWN_DM_AUTOACCEPT_MAX,
        "no extra silent group after the reopen"
    );
}

/// #419 review round 3: the budget must fail CLOSED when it cannot be made
/// durable. Recording the slot AFTER `accept_welcome` meant a failed sidecar
/// write returned success with the budget unconsumed, so the next engine (the
/// NSE opens its own) loaded a stale window and granted another full set of
/// automatic accepts — the limiter vanished exactly when the filesystem was
/// under contention or the NSE was killed mid-write.
///
/// A directory sitting at the sidecar path makes the rename fail the same way.
#[tokio::test]
async fn unpersistable_budget_parks_instead_of_auto_accepting() {
    let dir = tempfile::tempdir().expect("tempdir");
    let db_path = dir.path().join("marmot.sqlite");
    // Occupy the sidecar path with a directory: tmp+rename cannot replace it.
    std::fs::create_dir(dir.path().join("marmot.sqlite.dm-autoaccepts.json"))
        .expect("block the sidecar path");

    let bob = MarmotEngine::persistent(Identity::generate(), &db_path, [0x42u8; 32])
        .expect("open");
    let (_s, wrapped) = stranger_dm_welcome(&bob).await;
    match bob.process_incoming(&wrapped).await.expect("process") {
        Incoming::GroupInvitePending(_) => {}
        other => panic!(
            "a budget that cannot be persisted must park the welcome, not \
             auto-accept it, got {other:?}"
        ),
    }
    assert_eq!(
        bob.groups().expect("groups").len(),
        0,
        "no silent group may be created on a budget we cannot account for"
    );
}

/// #419 review round 2: a DM-only ceiling was walk-aroundable by minting
/// 3-member groups instead. The cap counts pending invites of every size.
#[tokio::test]
async fn multi_member_invite_flood_is_capped_too() {
    let relay = RelayUrl::parse("wss://relay.example.com").expect("relay url");
    let bob = MarmotEngine::in_memory(Identity::generate());

    let mut pending = 0usize;
    let mut dropped = 0usize;
    for _ in 0..(PENDING_INVITE_CAP + 10) {
        // A 3-member group: bob + the stranger + one filler member.
        let stranger = MarmotEngine::in_memory(Identity::generate());
        let filler = MarmotEngine::in_memory(Identity::generate());
        let bob_kp = bob.key_package_event(vec![relay.clone()]).expect("bob kp");
        let filler_kp = filler
            .key_package_event(vec![relay.clone()])
            .expect("filler kp");
        let creation = stranger
            .create_group("spam", vec![bob_kp, filler_kp], vec![relay.clone()])
            .expect("create 3-member group");
        let (pk, welcome) = creation
            .welcomes
            .iter()
            .find(|(pubkey, _)| *pubkey == bob.identity().public_key())
            .cloned()
            .expect("bob welcome");
        let wrapped = stranger
            .gift_wrap_welcome(&pk, welcome)
            .await
            .expect("wrap welcome");
        match bob.process_incoming(&wrapped).await.expect("process") {
            Incoming::GroupInvitePending(_) => pending += 1,
            Incoming::None => dropped += 1,
            other => panic!("unexpected {other:?}"),
        }
    }

    assert_eq!(pending, PENDING_INVITE_CAP, "parked invites stop at the cap");
    assert!(dropped > 0, "past the cap, welcomes are dropped");
    assert_eq!(
        bob.pending_group_invites().expect("invites").len(),
        PENDING_INVITE_CAP,
        "the invite list must not grow past the ceiling for ANY group size"
    );

    // #419 is a STORAGE denial of service, so bounding the invite list is only
    // half of it. `process_welcome` persists the welcome and a group row before
    // we get to decide, and `decline_welcome` only marks them Declined/Inactive
    // — so a ceiling that stops at declining still lets an attacker grow the
    // SQLCipher database ~5KB per event forever. Every dropped welcome must
    // leave NO row behind.
    assert_eq!(
        bob.stored_group_count().expect("stored groups"),
        PENDING_INVITE_CAP,
        "dropped welcomes must not leave stored group rows behind — the \
         database, not just the invite list, is what #419 bounds"
    );
}
