# PTT Talk Promptfoo campaigns

Promptfoo is the repository's campaign orchestrator and evidence formatter. It
does not replace the deterministic native tools that prove cryptography, mobile
lifecycle, speaker output, infrastructure recovery, or authorization. The
allowlisted provider runs those tools and emits one redacted, hashed evidence
record per lane.

## Safety contract

- Test prompts select only static commands from `providers/lane-provider.mjs`.
- Prompt content is never interpolated into a command.
- Telemetry and remote red-team generation are disabled by the launcher.
- Output is redacted and limited before it enters Promptfoo artifacts.
- Tests use synthetic identities and disposable infrastructure.
- Missing devices or credentials fail their requested lane; they are never
  silently reported as skipped or passed.

## Run

From the repository root:

```sh
./scripts/run-promptfoo-suite.sh pr
./scripts/run-promptfoo-suite.sh nightly
./scripts/run-promptfoo-suite.sh weekly
./scripts/run-promptfoo-suite.sh browser
./scripts/run-promptfoo-suite.sh adversarial
./scripts/run-promptfoo-suite.sh release
./scripts/run-promptfoo-suite.sh release-aggregate
```

Evidence is stored under `artifacts/promptfoo/<commit>/<profile>/`. The output
is local and ignored by Git.

## Cadence

- `pr`: portable contracts and test-fixture self-tests.
- `nightly`: application, service, crypto, integration and security suites.
- `weekly`: disposable K3s and interface/accessibility matrices.
- `browser`: rendered public product, deployment, and privacy journeys.
- `adversarial`: deterministic API and authorization regression campaigns.
- `release`: focused two-iOS acoustic and restoration proof, full four-device
  physical parity, restoration, eight-hour soak and release readiness. This
  profile requires the physical-device environment variables documented by the
  underlying scripts.
- `release-aggregate`: verifies that CI, production voice, physical, soak,
  version, store, and push gates passed for one clean exact commit.

The reusable custom policy in `policies/ptt-security.yaml` is reserved for
generating additional synthetic attacks in an approved isolated environment.
Generated cases must be reviewed and converted into deterministic regressions
before they can become release gates.
