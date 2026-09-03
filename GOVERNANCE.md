# Project governance

PTT Talk currently uses a maintainer-led governance model. The goal is to make
technical decisions openly while keeping security-critical changes deliberate
and reviewable.

## Participation

- **Contributors** open issues, join discussions, improve documentation, test,
  and submit pull requests.
- **Reviewers** provide repeatable technical review in areas where they have
  demonstrated context and care.
- **Maintainers** merge changes, manage releases and infrastructure, moderate
  community spaces, and make final decisions when consensus is not reached.

The current lead maintainer is `@golanbenoni`. Additional reviewers and
maintainers may be recognized through sustained, trustworthy contributions.

## Decisions

Small, reversible changes can be decided in a pull request. Changes to the wire
protocol, cryptography, identity, recovery, retention, floor behavior, release
gates, or supported infrastructure begin in a GitHub Discussion or design issue
and include:

1. the user or operator problem;
2. security, privacy, compatibility, and self-hosting consequences;
3. alternatives considered;
4. test and migration plans; and
5. rollback or failure behavior.

Consensus is preferred. The lead maintainer resolves deadlocks and documents
the reason for security- or compatibility-sensitive decisions.

## Releases and security

Only maintainers publish mobile, container, chart, or hosted-service releases.
A release must identify its source commit, version, protocol compatibility, test
evidence, and known gaps. Public-source availability does not remove the beta
gates in [`docs/RELEASE_STATUS.md`](docs/RELEASE_STATUS.md).

Vulnerabilities are handled privately under [`SECURITY.md`](SECURITY.md).
Security fixes may be developed outside the public issue flow until coordinated
disclosure is safe.
