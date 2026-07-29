//! sonar-sim — multi-agent Marmot/MLS swarm simulation.
//!
//! Spawns N in-process `MarmotEngine` agents (the exact MLS/Marmot code the
//! apps ship), builds ever-bigger groups, verifies message fan-out at each
//! size, and measures the wire artifacts relays actually have to carry —
//! most importantly the gift-wrapped kind-1059 welcome, which embeds the
//! MLS ratchet tree and therefore grows linearly with member count.
//!
//! The practical group-size ceiling in production is the largest N whose
//! welcome still fits under the relays' NIP-11 `max_message_length`; the
//! `group-scale` command measures the size curve, fetches the live limits
//! from the bootstrap relays, and reports the per-relay ceiling.
//!
//! Events are delivered agent-to-agent in process (no relay I/O), in the
//! order a relay would serialize them, so protocol failures found here are
//! protocol bugs, not network flakes. `--chaos` additionally races two
//! same-epoch add commits (the classic MLS fork scenario) and reports
//! whether the group converges.

use std::path::PathBuf;
use std::time::Instant;

use clap::{Args, Parser, Subcommand, ValueEnum};
use nostr::{JsonUtil, PublicKey, RelayUrl};
use serde::Serialize;
use sonar_core::identity::Identity;
use sonar_core::marmot::{Incoming, MarmotEngine};
use sonar_core::GroupId;

/// Default relay set to fetch NIP-11 limits from — the Sonar bootstrap
/// relays plus the official White Noise relays (`core/sonar-status`).
const DEFAULT_NIP11_RELAYS: &[&str] = &[
    "wss://relay.damus.io",
    "wss://nos.lol",
    "wss://relay.primal.net",
    "wss://offchain.pub",
    "wss://nostr21.com",
    "wss://relay.kaleidoswap.com",
    "wss://nostr.relay.hedwig.sh",
    "wss://relay.us.whitenoise.chat",
    "wss://relay.eu.whitenoise.chat",
];

#[derive(Parser, Debug)]
#[command(
    name = "sonar-sim",
    about = "Multi-agent Marmot/MLS swarm simulation for scale limits and protocol bugs"
)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand, Debug)]
enum Command {
    /// Grow a group across a ramp of sizes, verify fan-out, measure wire sizes.
    GroupScale(ScaleArgs),
}

#[derive(Args, Debug)]
struct ScaleArgs {
    /// Comma-separated group sizes to test, in order. Stops at the first hard failure.
    #[arg(long, default_value = "2,5,10,25,50,100,150,200,300")]
    ramp: String,
    /// How the group reaches size N.
    #[arg(long, value_enum, default_value_t = Mode::Incremental)]
    mode: Mode,
    /// Members added per commit in incremental mode.
    #[arg(long, default_value_t = 25)]
    batch: usize,
    /// How many distinct members send a probe message at each size.
    #[arg(long, default_value_t = 5)]
    senders: usize,
    /// Race two same-epoch add commits at each size and check convergence.
    #[arg(long)]
    chaos: bool,
    /// Skip fetching NIP-11 limits from the live relays.
    #[arg(long)]
    no_nip11: bool,
    /// Write the full JSON report here.
    #[arg(long)]
    out: Option<PathBuf>,
}

#[derive(ValueEnum, Clone, Copy, Debug, PartialEq, Eq)]
enum Mode {
    /// One creation commit carrying every member's KeyPackage.
    CreateAll,
    /// Create small, then `add_members` in batches — the path real clients take.
    Incremental,
}

#[derive(Serialize)]
struct Report {
    mode: String,
    steps: Vec<StepResult>,
    chaos: Vec<ChaosResult>,
    relay_limits: Vec<RelayLimit>,
    /// Per relay: largest measured N whose welcome fits the relay limit.
    ceilings: Vec<Ceiling>,
}

#[derive(Serialize)]
struct StepResult {
    n: usize,
    ok: bool,
    /// Largest gift-wrapped kind-1059 welcome, serialized as relays see it.
    max_welcome_bytes: usize,
    /// Largest kind-445 commit/evolution event.
    max_evolution_bytes: usize,
    /// A kind-445 text message event at this group size.
    message_bytes: usize,
    setup_ms: u128,
    build_ms: u128,
    fanout_ms: u128,
    /// members()==N checks that failed, as "agent-<i>: got M".
    convergence_errors: Vec<String>,
    /// fan-out deliveries that did not produce Incoming::Message.
    delivery_errors: Vec<String>,
    /// Unexpected Incoming variants and hard errors with context.
    anomalies: Vec<String>,
}

#[derive(Serialize)]
struct ChaosResult {
    n: usize,
    /// What each side's stale/winning commit produced on delivery.
    outcomes: Vec<String>,
    converged: bool,
    post_race_fanout_ok: bool,
    findings: Vec<String>,
}

#[derive(Serialize)]
struct RelayLimit {
    relay: String,
    /// NIP-11 limitation.max_message_length (bytes), if advertised.
    max_message_length: Option<u64>,
    error: Option<String>,
}

#[derive(Serialize)]
struct Ceiling {
    relay: String,
    limit_bytes: u64,
    /// Largest tested N whose welcome fit, and the first tested N that did not.
    max_fitting_n: Option<usize>,
    first_overflow_n: Option<usize>,
}

struct Agent {
    engine: MarmotEngine,
    pk: PublicKey,
    /// Accepted the welcome and is an active group member.
    active: bool,
}

fn group_relays() -> Vec<RelayUrl> {
    // Metadata only in this simulation — nothing connects to it.
    vec![RelayUrl::parse("wss://relay.example.com").expect("static relay url")]
}

fn new_agent() -> Agent {
    let identity = Identity::generate();
    let pk = identity.public_key();
    Agent {
        engine: MarmotEngine::in_memory(identity),
        pk,
        active: false,
    }
}

/// Deliver one event to one agent. Returns the classified result, or the
/// engine error as a string. The caller logs exactly once — `deliver` never
/// pushes, so a single failed recipient can't be counted twice.
async fn deliver(agent: &Agent, event: &nostr::Event) -> Result<Incoming, String> {
    agent
        .engine
        .process_incoming(event)
        .await
        .map_err(|e| e.to_string())
}

/// Gift-wrap a welcome from `sender`, deliver it to `invitee`, and accept it.
/// Marks `invitee.active` on success. Returns the wrapped welcome size, or one
/// error string describing where the join failed. `sender` and `invitee` must be
/// distinct agents (the borrow checker enforces this at call sites).
async fn wrap_and_accept(
    sender: &Agent,
    invitee: &mut Agent,
    member_pk: &PublicKey,
    welcome: nostr::UnsignedEvent,
) -> Result<usize, String> {
    let wrapped = sender
        .engine
        .gift_wrap_welcome(member_pk, welcome)
        .await
        .map_err(|e| format!("gift_wrap_welcome({member_pk}): {e}"))?;
    let size = wrapped.as_json().len();
    match deliver(invitee, &wrapped).await? {
        Incoming::GroupInvitePending(_) => {
            let invites = invitee
                .engine
                .pending_group_invites()
                .map_err(|e| format!("pending_group_invites({member_pk}): {e}"))?;
            let invite = invites
                .first()
                .ok_or_else(|| format!("welcome delivered to {member_pk} but no pending invite"))?;
            invitee
                .engine
                .accept_group_invite(&invite.id)
                .map_err(|e| format!("accept_group_invite({member_pk}): {e}"))?;
            invitee.active = true;
        }
        // 2-member groups auto-join on welcome (DM semantics).
        Incoming::GroupUpdated(_) => invitee.active = true,
        other => return Err(format!("welcome to {member_pk} produced {other:?}")),
    }
    Ok(size)
}

/// Wrap and deliver welcomes to their target members, have them accept, mark
/// active. Returns the largest wrapped welcome size seen.
async fn deliver_welcomes(
    creator: &Agent,
    agents: &mut [Agent],
    welcomes: &[(PublicKey, nostr::UnsignedEvent)],
    anomalies: &mut Vec<String>,
) -> usize {
    let mut max_welcome = 0usize;
    for (member_pk, welcome) in welcomes {
        let Some(agent) = agents.iter_mut().find(|a| a.pk == *member_pk) else {
            anomalies.push(format!("welcome for unknown member {member_pk}"));
            continue;
        };
        match wrap_and_accept(creator, agent, member_pk, welcome.clone()).await {
            Ok(size) => max_welcome = max_welcome.max(size),
            Err(e) => anomalies.push(e),
        }
    }
    max_welcome
}

/// Fan an event out to every active agent except `skip`. Returns the number of
/// **distinct recipients** that did not accept it (one per broken member, never
/// two), and appends one diagnostic per broken recipient to `errors`.
async fn fan_out(
    agents: &mut [Agent],
    skip: PublicKey,
    event: &nostr::Event,
    expect_message: bool,
    errors: &mut Vec<String>,
) -> usize {
    let want = if expect_message {
        "Message"
    } else {
        "GroupUpdated"
    };
    let mut broken = 0;
    for (i, agent) in agents.iter_mut().enumerate() {
        if !agent.active || agent.pk == skip {
            continue;
        }
        match deliver(agent, event).await {
            Ok(Incoming::Message(_)) if expect_message => {}
            Ok(Incoming::GroupUpdated(_)) if !expect_message => {}
            Ok(other) => {
                errors.push(format!("agent-{i}: expected {want}, got {other:?}"));
                broken += 1;
            }
            Err(e) => {
                errors.push(format!("agent-{i}: process_incoming failed: {e}"));
                broken += 1;
            }
        }
    }
    broken
}

async fn run_step(
    n: usize,
    mode: Mode,
    batch: usize,
    senders: usize,
) -> (StepResult, Option<(Vec<Agent>, GroupId)>) {
    let relays = group_relays();
    let mut anomalies = Vec::new();
    let mut convergence_errors = Vec::new();
    let mut delivery_errors = Vec::new();
    let mut max_welcome = 0usize;
    let mut max_evolution = 0usize;

    let t_setup = Instant::now();
    let mut agents: Vec<Agent> = (0..n).map(|_| new_agent()).collect();
    agents[0].active = true; // creator
    let setup_ms = t_setup.elapsed().as_millis();

    let t_build = Instant::now();
    let creator_pk = agents[0].pk;

    // Key packages for everyone but the creator.
    let mut kps = Vec::with_capacity(n - 1);
    for agent in &agents[1..] {
        match agent.engine.key_package_event(relays.clone()).await {
            Ok(kp) => kps.push(kp),
            Err(e) => anomalies.push(format!("key_package_event({}): {e}", agent.pk)),
        }
    }

    let first_wave = match mode {
        Mode::CreateAll => kps.len(),
        Mode::Incremental => batch.min(kps.len()),
    };

    let creation = match agents[0].engine.create_group(
        &format!("sim-scale-{n}"),
        kps[..first_wave].to_vec(),
        relays.clone(),
    ) {
        Ok(c) => c,
        Err(e) => {
            return (
                StepResult {
                    n,
                    ok: false,
                    max_welcome_bytes: 0,
                    max_evolution_bytes: 0,
                    message_bytes: 0,
                    setup_ms,
                    build_ms: t_build.elapsed().as_millis(),
                    fanout_ms: 0,
                    convergence_errors,
                    delivery_errors,
                    anomalies: vec![format!("create_group(n={n}): {e}")],
                },
                None,
            )
        }
    };
    let group_id = creation.group.mls_group_id.clone();
    if let Err(e) = agents[0].engine.merge_pending_commit(&group_id) {
        anomalies.push(format!("creator merge_pending_commit: {e}"));
    }
    let creator = std::mem::replace(&mut agents[0], new_agent());
    max_welcome = max_welcome.max(
        deliver_welcomes(
            &creator,
            &mut agents[1..],
            &creation.welcomes,
            &mut anomalies,
        )
        .await,
    );
    agents[0] = creator;

    // Incremental: add the rest in batches; existing members apply each commit.
    let mut added = first_wave;
    while added < kps.len() {
        let chunk = &kps[added..(added + batch).min(kps.len())];
        let update = match agents[0].engine.add_members(&group_id, chunk.to_vec()) {
            Ok(u) => u,
            Err(e) => {
                anomalies.push(format!("add_members(at {added}): {e}"));
                break;
            }
        };
        max_evolution = max_evolution.max(update.evolution_event.as_json().len());
        // Relay order: commit first to existing members, then welcomes.
        let _ = fan_out(
            &mut agents,
            creator_pk,
            &update.evolution_event,
            false,
            &mut delivery_errors,
        )
        .await;
        let creator = std::mem::replace(&mut agents[0], new_agent());
        max_welcome = max_welcome.max(
            deliver_welcomes(&creator, &mut agents[1..], &update.welcomes, &mut anomalies).await,
        );
        agents[0] = creator;
        if update.requires_commit_merge {
            if let Err(e) = agents[0].engine.merge_pending_commit(&group_id) {
                anomalies.push(format!("merge_pending_commit(at {added}): {e}"));
            }
        }
        added += chunk.len();
    }
    let build_ms = t_build.elapsed().as_millis();

    // Convergence: every active member must see the exact same member SET — the
    // roster of all N agent public keys, not merely a count of N. An MDK change
    // that leaves an agent with the right number of *different* members must fail
    // here, so we compare pubkey sets, not lengths.
    let expected: std::collections::BTreeSet<PublicKey> = agents.iter().map(|a| a.pk).collect();
    for (i, agent) in agents.iter().enumerate() {
        if !agent.active {
            convergence_errors.push(format!("agent-{i}: never became active"));
            continue;
        }
        match agent.engine.members(&group_id) {
            Ok(members) => {
                let got: std::collections::BTreeSet<PublicKey> = members.into_iter().collect();
                if got != expected {
                    let missing = expected.difference(&got).count();
                    let extra = got.difference(&expected).count();
                    convergence_errors.push(format!(
                        "agent-{i}: roster mismatch ({} members: {missing} missing, {extra} unexpected, want {n})",
                        got.len()
                    ));
                }
            }
            Err(e) => convergence_errors.push(format!("agent-{i}: members(): {e}")),
        }
    }

    // Fan-out: `senders` spread across the roster each send one message.
    let t_fanout = Instant::now();
    let mut message_bytes = 0usize;
    let sender_idxs: Vec<usize> = (0..senders.min(n))
        .map(|k| k * n / senders.min(n))
        .collect();
    for &idx in &sender_idxs {
        let text = format!("probe from agent-{idx} at n={n}");
        let event = {
            let agent = &agents[idx];
            if !agent.active {
                continue;
            }
            match agent
                .engine
                .create_and_process_text_message(&group_id, &text)
            {
                Ok((ev, _)) => ev,
                Err(e) => {
                    delivery_errors.push(format!("agent-{idx}: create message: {e}"));
                    continue;
                }
            }
        };
        message_bytes = message_bytes.max(event.as_json().len());
        let sender_pk = agents[idx].pk;
        let _ = fan_out(&mut agents, sender_pk, &event, true, &mut delivery_errors).await;
    }
    let fanout_ms = t_fanout.elapsed().as_millis();

    let ok = convergence_errors.is_empty() && delivery_errors.is_empty() && anomalies.is_empty();
    let step = StepResult {
        n,
        ok,
        max_welcome_bytes: max_welcome,
        max_evolution_bytes: max_evolution,
        message_bytes,
        setup_ms,
        build_ms,
        fanout_ms,
        convergence_errors,
        delivery_errors,
        anomalies,
    };
    let swarm = if step.ok {
        Some((agents, group_id))
    } else {
        None
    };
    (step, swarm)
}

/// Race two same-epoch add commits and see whether the group converges.
async fn run_chaos(mut agents: Vec<Agent>, group_id: GroupId, n: usize) -> ChaosResult {
    let relays = group_relays();
    let mut outcomes = Vec::new();
    let mut findings = Vec::new();

    let fresh_a = new_agent();
    let fresh_b = new_agent();
    let kp_a = fresh_a.engine.key_package_event(relays.clone()).await;
    let kp_b = fresh_b.engine.key_package_event(relays).await;
    let (Ok(kp_a), Ok(kp_b)) = (kp_a, kp_b) else {
        return ChaosResult {
            n,
            outcomes: vec!["key package generation failed".into()],
            converged: false,
            post_race_fanout_ok: false,
            findings: vec!["setup failure before race".into()],
        };
    };

    // Both commits are created from the SAME epoch before either is delivered —
    // exactly what two admins on different phones do at the same moment. Prefer
    // two non-creator members; a 2-member group races creator vs member.
    let (committer_a, committer_b) = if agents.len() >= 3 { (1, 2) } else { (0, 1) };
    let update_a = agents[committer_a]
        .engine
        .add_members(&group_id, vec![kp_a]);
    let update_b = agents[committer_b]
        .engine
        .add_members(&group_id, vec![kp_b]);
    let (Ok(update_a), Ok(update_b)) = (update_a, update_b) else {
        return ChaosResult {
            n,
            outcomes: vec!["concurrent add_members failed to stage".into()],
            converged: false,
            post_race_fanout_ok: false,
            findings: vec!["could not stage concurrent commits".into()],
        };
    };

    // The relay serializes: A's commit lands first everywhere, then B's stale one.
    for (label, update, committer) in [
        ("A(wins)", &update_a, committer_a),
        ("B(stale)", &update_b, committer_b),
    ] {
        for (i, agent) in agents.iter().enumerate() {
            if i == committer || !agent.active {
                continue;
            }
            match agent.engine.process_incoming(&update.evolution_event).await {
                Ok(incoming) => outcomes.push(format!("{label} -> agent-{i}: {incoming:?}")),
                Err(e) => outcomes.push(format!("{label} -> agent-{i}: ERR {e}")),
            }
        }
        if update.requires_commit_merge {
            if let Err(e) = agents[committer].engine.merge_pending_commit(&group_id) {
                outcomes.push(format!("{label} committer merge: {e}"));
            }
        }
    }
    // Deliver each committer's welcome to ITS invitee and fold both into the
    // swarm: fresh_a joins via the winning commit, fresh_b via the stale one.
    // Without this, an invitee stranded on the losing branch is silently dropped
    // and the group can report converged while a new member is isolated.
    let mut fresh_a = fresh_a;
    let mut fresh_b = fresh_b;
    for (committer, update, invitee) in [
        (committer_a, &update_a, &mut fresh_a),
        (committer_b, &update_b, &mut fresh_b),
    ] {
        let invitee_pk = invitee.pk;
        match update.welcomes.iter().find(|(pk, _)| *pk == invitee_pk) {
            Some((pk, welcome)) => {
                if let Err(e) =
                    wrap_and_accept(&agents[committer], invitee, pk, welcome.clone()).await
                {
                    outcomes.push(format!("invitee {invitee_pk} join: {e}"));
                }
            }
            None => outcomes.push(format!("no welcome staged for invitee {invitee_pk}")),
        }
    }
    agents.push(fresh_a);
    agents.push(fresh_b);

    // Keep chaos output readable: dedupe identical outcomes into counts.
    outcomes = summarize_outcomes(outcomes);

    // Convergence: do ALL active members (originals + both invitees) agree on the
    // member SET? Counts are not enough — two racing add-commits both grow the
    // group by one, so a fork keeps the count identical while the rosters differ.
    let mut branches: std::collections::BTreeMap<Vec<String>, Vec<usize>> =
        std::collections::BTreeMap::new();
    let mut roster_errors = Vec::new();
    for (i, agent) in agents.iter().enumerate() {
        if !agent.active {
            continue;
        }
        // A members() failure must NOT collapse to an empty roster — otherwise
        // several unreadable agents would all land in the same empty bucket and
        // masquerade as convergence. Record it as its own non-convergence signal.
        match agent.engine.members(&group_id) {
            Ok(m) => {
                let mut roster: Vec<String> =
                    m.iter().map(|pk| pk.to_hex()[..8].to_owned()).collect();
                roster.sort();
                branches.entry(roster).or_default().push(i);
            }
            Err(e) => roster_errors.push(format!("agent-{i}: members(): {e}")),
        }
    }
    let converged = branches.len() == 1 && roster_errors.is_empty();
    if !roster_errors.is_empty() {
        let sample: Vec<_> = roster_errors.iter().take(3).cloned().collect();
        findings.push(format!(
            "{} agent(s) could not read group state after the race: {sample:?}",
            roster_errors.len()
        ));
    }
    if branches.len() > 1 {
        findings.push(format!(
            "group forked into {} branches after concurrent commits; populations: {:?}",
            branches.len(),
            branches.values().map(Vec::len).collect::<Vec<_>>()
        ));
    }

    // Can the group still talk? Fan a message from the winning committer and
    // count DISTINCT broken recipients (fan_out returns one per member).
    let mut post_errors = Vec::new();
    let sender_pk = agents[committer_a].pk;
    let (broken, sender_failed) = match agents[committer_a]
        .engine
        .create_and_process_text_message(&group_id, "post-race probe")
    {
        Ok((ev, _)) => (
            fan_out(&mut agents, sender_pk, &ev, true, &mut post_errors).await,
            false,
        ),
        Err(e) => {
            post_errors.push(format!("winner cannot send after race: {e}"));
            (0, true)
        }
    };
    let post_race_fanout_ok = post_errors.is_empty();
    if !post_race_fanout_ok {
        let sample: Vec<_> = post_errors.iter().take(3).cloned().collect();
        let label = if sender_failed {
            "the winner could not send after the race".to_string()
        } else {
            format!("{broken} member(s) could not read the winner's message after the race")
        };
        findings.push(format!("{label}; first: {sample:?}"));
    }

    ChaosResult {
        n,
        outcomes,
        converged,
        post_race_fanout_ok,
        findings,
    }
}

fn summarize_outcomes(outcomes: Vec<String>) -> Vec<String> {
    let mut counts: Vec<(String, usize)> = Vec::new();
    for outcome in outcomes {
        // Strip the per-agent index so identical results collapse.
        let key = match outcome.split_once(" -> ") {
            Some((label, rest)) => match rest.split_once(": ") {
                Some((_, result)) => format!("{label}: {result}"),
                None => outcome.clone(),
            },
            None => outcome.clone(),
        };
        match counts.iter_mut().find(|(k, _)| *k == key) {
            Some((_, c)) => *c += 1,
            None => counts.push((key, 1)),
        }
    }
    counts
        .into_iter()
        .map(|(k, c)| format!("{c}x {k}"))
        .collect()
}

async fn fetch_nip11(relay: &str) -> RelayLimit {
    let http = relay.replacen("wss://", "https://", 1);
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(8))
        .build();
    let client = match client {
        Ok(c) => c,
        Err(e) => {
            return RelayLimit {
                relay: relay.into(),
                max_message_length: None,
                error: Some(e.to_string()),
            }
        }
    };
    match client
        .get(&http)
        .header("Accept", "application/nostr+json")
        .send()
        .await
    {
        Ok(resp) => match resp.json::<serde_json::Value>().await {
            Ok(doc) => RelayLimit {
                relay: relay.into(),
                max_message_length: doc
                    .pointer("/limitation/max_message_length")
                    .and_then(|v| v.as_u64()),
                error: None,
            },
            Err(e) => RelayLimit {
                relay: relay.into(),
                max_message_length: None,
                error: Some(format!("bad NIP-11 JSON: {e}")),
            },
        },
        Err(e) => RelayLimit {
            relay: relay.into(),
            max_message_length: None,
            error: Some(e.to_string()),
        },
    }
}

fn ceilings(steps: &[StepResult], limits: &[RelayLimit]) -> Vec<Ceiling> {
    limits
        .iter()
        .filter_map(|l| {
            let limit = l.max_message_length?;
            let mut max_fitting_n = None;
            let mut first_overflow_n = None;
            for s in steps {
                // Only successful steps have a trustworthy welcome size for their
                // N. A failed step keeps the last *successful* wrap (its own
                // welcome was never produced), so counting it would report a
                // failed N as "fits" against a relay it never reached.
                if !s.ok || s.max_welcome_bytes == 0 {
                    continue;
                }
                if (s.max_welcome_bytes as u64) <= limit {
                    max_fitting_n = Some(s.n);
                } else if first_overflow_n.is_none() {
                    first_overflow_n = Some(s.n);
                }
            }
            Some(Ceiling {
                relay: l.relay.clone(),
                limit_bytes: limit,
                max_fitting_n,
                first_overflow_n,
            })
        })
        .collect()
}

#[tokio::main]
async fn main() {
    let cli = Cli::parse();
    let Command::GroupScale(args) = cli.command;

    let ramp: Vec<usize> = args
        .ramp
        .split(',')
        .filter_map(|s| s.trim().parse().ok())
        .filter(|&n| n >= 2)
        .collect();
    if ramp.is_empty() {
        eprintln!("error: --ramp has no sizes >= 2");
        std::process::exit(1);
    }

    let mut steps = Vec::new();
    let mut chaos_results = Vec::new();
    for &n in &ramp {
        eprintln!("── n={n} ({:?}, batch {}) ──", args.mode, args.batch);
        let (step, swarm) = run_step(n, args.mode, args.batch, args.senders).await;
        eprintln!(
            "   {} · welcome {} B · evolution {} B · message {} B · build {} ms · fanout {} ms",
            if step.ok { "ok" } else { "FAILED" },
            step.max_welcome_bytes,
            step.max_evolution_bytes,
            step.message_bytes,
            step.build_ms,
            step.fanout_ms,
        );
        // Anomalies first: they carry the root cause (e.g. `gift_wrap_welcome:
        // message too long`), whereas convergence errors are usually derivative
        // ("never became active") and would otherwise crowd the cause out of a
        // truncated view.
        for e in step
            .anomalies
            .iter()
            .chain(&step.delivery_errors)
            .chain(&step.convergence_errors)
            .take(6)
        {
            eprintln!("   ! {e}");
        }
        let failed = !step.ok;
        steps.push(step);
        if let Some((agents, group_id)) = swarm {
            if args.chaos {
                eprintln!("   chaos: racing two same-epoch add commits…");
                let chaos = run_chaos(agents, group_id, n).await;
                eprintln!(
                    "   chaos: converged={} post_race_fanout_ok={}",
                    chaos.converged, chaos.post_race_fanout_ok
                );
                for f in &chaos.findings {
                    eprintln!("   ! {f}");
                }
                chaos_results.push(chaos);
            }
        }
        if failed {
            eprintln!("stopping ramp at first failure (n={n})");
            break;
        }
    }

    let relay_limits = if args.no_nip11 {
        Vec::new()
    } else {
        let mut limits = Vec::new();
        for relay in DEFAULT_NIP11_RELAYS {
            limits.push(fetch_nip11(relay).await);
        }
        limits
    };
    let ceilings = ceilings(&steps, &relay_limits);

    let report = Report {
        mode: format!("{:?}", args.mode),
        steps,
        chaos: chaos_results,
        relay_limits,
        ceilings,
    };

    // Human summary.
    println!("\nn      welcome(B)  evolution(B)  message(B)  build(ms)  fanout(ms)  ok");
    for s in &report.steps {
        println!(
            "{:<6} {:<11} {:<13} {:<11} {:<10} {:<11} {}",
            s.n,
            s.max_welcome_bytes,
            s.max_evolution_bytes,
            s.message_bytes,
            s.build_ms,
            s.fanout_ms,
            s.ok
        );
    }
    if !report.ceilings.is_empty() {
        println!("\nrelay ceilings (welcome must fit NIP-11 max_message_length):");
        for c in &report.ceilings {
            println!(
                "  {:<38} limit {:>8} B · max tested N that fits: {} · first overflow: {}",
                c.relay,
                c.limit_bytes,
                c.max_fitting_n.map_or("-".into(), |n| n.to_string()),
                c.first_overflow_n.map_or("-".into(), |n| n.to_string()),
            );
        }
    }
    for l in &report.relay_limits {
        if l.max_message_length.is_none() {
            println!(
                "  {:<38} no NIP-11 limit advertised{}",
                l.relay,
                l.error
                    .as_deref()
                    .map(|e| format!(" ({e})"))
                    .unwrap_or_default()
            );
        }
    }

    if let Some(path) = &args.out {
        match serde_json::to_vec_pretty(&report) {
            Ok(json) => {
                if let Err(e) = std::fs::write(path, json) {
                    eprintln!("error: write {}: {e}", path.display());
                    std::process::exit(1);
                }
                eprintln!("report: {}", path.display());
            }
            Err(e) => {
                eprintln!("error: serialize report: {e}");
                std::process::exit(1);
            }
        }
    }

    if report.steps.iter().any(|s| !s.ok) {
        std::process::exit(2);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn step(n: usize, welcome: usize) -> StepResult {
        step_with(n, welcome, true)
    }

    fn step_with(n: usize, welcome: usize, ok: bool) -> StepResult {
        StepResult {
            n,
            ok,
            max_welcome_bytes: welcome,
            max_evolution_bytes: 0,
            message_bytes: 0,
            setup_ms: 0,
            build_ms: 0,
            fanout_ms: 0,
            convergence_errors: vec![],
            delivery_errors: vec![],
            anomalies: vec![],
        }
    }

    #[test]
    fn ceiling_ignores_failed_steps() {
        // The 130 step FAILED (welcome could not be produced) but still carries
        // the previous successful welcome size. It must not be reported as
        // fitting the relay: max_fitting_n stays at the last *successful* N.
        let steps = vec![step(100, 77_000), step_with(130, 77_000, false)];
        let limits = vec![RelayLimit {
            relay: "wss://r".into(),
            max_message_length: Some(131_072),
            error: None,
        }];
        let c = &ceilings(&steps, &limits)[0];
        assert_eq!(c.max_fitting_n, Some(100));
        assert_eq!(c.first_overflow_n, None);
    }

    #[test]
    fn ceiling_splits_fitting_from_overflow() {
        let steps = vec![step(10, 10_000), step(50, 60_000), step(100, 130_000)];
        let limits = vec![RelayLimit {
            relay: "wss://r".into(),
            max_message_length: Some(65_536),
            error: None,
        }];
        let c = &ceilings(&steps, &limits)[0];
        assert_eq!(c.max_fitting_n, Some(50));
        assert_eq!(c.first_overflow_n, Some(100));
    }

    #[test]
    fn ceiling_reports_no_overflow_when_all_fit() {
        let steps = vec![step(10, 10_000), step(50, 60_000)];
        let limits = vec![RelayLimit {
            relay: "wss://r".into(),
            max_message_length: Some(1_000_000),
            error: None,
        }];
        let c = &ceilings(&steps, &limits)[0];
        assert_eq!(c.max_fitting_n, Some(50));
        assert_eq!(c.first_overflow_n, None);
    }

    #[test]
    fn ceiling_skips_relays_without_an_advertised_limit() {
        let steps = vec![step(10, 10_000)];
        let limits = vec![RelayLimit {
            relay: "wss://r".into(),
            max_message_length: None,
            error: Some("timeout".into()),
        }];
        assert!(ceilings(&steps, &limits).is_empty());
    }

    #[test]
    fn summarize_collapses_identical_per_agent_outcomes() {
        let raw = vec![
            "A(wins) -> agent-3: GroupUpdated(x)".into(),
            "A(wins) -> agent-4: GroupUpdated(x)".into(),
            "B(stale) -> agent-3: Failed".into(),
        ];
        let out = summarize_outcomes(raw);
        assert!(out.contains(&"2x A(wins): GroupUpdated(x)".to_string()));
        assert!(out.contains(&"1x B(stale): Failed".to_string()));
    }
}
