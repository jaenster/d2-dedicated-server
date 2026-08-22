# Security

## Reporting

Report anything exploitable privately: use
[GitHub's private advisory form](https://github.com/jaenster/d2-dedicated-server/security/advisories/new),
or send it over [Discord](https://discord.gg/MHK2Dg9) to `jaenster` if you would rather not open a
GitHub account. Please do not file a public issue for something that lets a client take down or take
over someone else's realm.

Expect a first answer within a few days. This is a spare-time project and there is no bounty.

## What is in scope

The servers in this repo — `realmd`, `d2ingress`, `d2gs` and `d2host` — parse packets from clients
that are, by construction, not trusted:

- anything a client can send that panics, hangs or corrupts state on the server
- reading or writing another account's characters, or taking over another player's session
- getting the realm to run something a player picked, or reach a host they picked

## What is not

- **The game engine's own bugs.** For the 1.14d and pre-1.14 servers, the world logic is Blizzard's
  binary running under this host. Report those upstream if there is an upstream; there is not.
- **A modded or hostile client doing things a client can do.** These servers are authoritative for
  the realm, not for every packet an unmodified client would never send. Client-side cheating is a
  known, unsolved class of problem for this game.
- **Running the stack open to the internet with the defaults.** `.env.example` ships development
  credentials and no TLS. That is a deployment choice, documented in
  [`docs/DEPLOY.md`](../docs/DEPLOY.md), not a vulnerability.

## Supported

The tip of `main` and the newest release tag. Nothing older is patched.
