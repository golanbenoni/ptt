# Contributing to PTT Talk

PTT Talk is an AGPLv3 project for private-team push-to-talk and collaboration.
Contributions are welcome as focused issues, design discussions, documentation,
tests, and pull requests.

## Before you start

- Read [`README.md`](README.md), [`docs/CURRENT_STATE.md`](docs/CURRENT_STATE.md),
  and [`docs/PROTOCOL_V1.md`](docs/PROTOCOL_V1.md).
- Use GitHub Discussions for architectural questions and Issues for a concrete
  bug or proposal.
- For protocol, cryptography, device identity, recovery, retention, or store
  behavior changes, open a design discussion before implementation.
- Report vulnerabilities through the private Security flow described in
  [`SECURITY.md`](SECURITY.md).

## Development workflow

1. Fork the repository and create a narrowly scoped branch.
2. Follow [`docs/DEPLOYMENT_GUIDE.md`](docs/DEPLOYMENT_GUIDE.md) for toolchains,
   local services, platform builds, and verification.
3. Add or update tests for behavior changes. Cross-platform wire changes need
   compatible Kotlin, Swift, and Rust coverage and updated golden vectors.
4. Run `node scripts/verify-documentation.mjs` and the relevant Android, iOS,
   Rust, web, infrastructure, and security checks documented in the deployment
   guide.
5. Open a pull request explaining the user impact, security impact, verification
   performed, and any known limitations.

Never commit `.env` files, signing material, store credentials, provisioning
profiles, push certificates, user exports, message or media content, or service
keys. Test fixtures must be synthetic and free of personal data.

## Product invariants

- No plaintext fallback for voice, messages, or attachments.
- Servers and object storage receive ciphertext, not content keys.
- Hardware and system PTT inputs use the same authenticated floor controller as
  the on-screen control.
- Removed devices and new devices cannot receive unauthorized history.
- Support logs must not expose keys, audio, message contents, email addresses,
  push tokens, or raw account/device/channel identifiers.
- Public-source status does not mean the current beta is approved for emergency
  services, life-safety, or general-production use.

Contributions are licensed under the repository's GNU Affero General Public
License v3.0.
