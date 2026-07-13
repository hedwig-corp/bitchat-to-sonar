sonar-ircd
==========

An IRC server that bridges to Sonar (sonar-core). Any IRC client (halloy, irssi,
weechat, ...) connects to this process as if it were an ordinary IRC server;
channels map to Sonar MLS groups, queries to 1:1 DMs. An optional [irc_bridge]
mirrors an external IRC channel into a local channel.

This is the in-tree consumer of sonar-core, a sibling to sonar-cli.

Run:

    cargo run -p sonar-ircd -- core/sonar-ircd/config.example.toml

Then point any IRC client at 127.0.0.1:6667 (no TLS). For halloy, add a
[servers.sonar] entry: server=127.0.0.1, port=6667, use_tls=false.

On first run an identity is generated under backend.home (default ~/.sonar-ircd);
set backend.nsec_file to import an existing one.

Layout: src/{main,config,backend,bridge,sonar,uplink}.rs + src/irc/{codec,server}.rs
