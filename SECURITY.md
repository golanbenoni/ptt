# Security policy

PTT Talk handles encrypted communications and device identity material. Please
report suspected vulnerabilities privately and give maintainers time to
investigate before public disclosure.

## Supported versions

The current `0.1.x` beta line and the latest commit on `main` receive security
fixes. Older builds may be required to upgrade or may have transmission disabled
when a protocol or cryptography issue cannot be handled safely.

## Reporting a vulnerability

Use GitHub's private vulnerability reporting flow:

1. Open the repository's **Security** tab.
2. Choose **Report a vulnerability**.
3. Include the affected platform and version, reproduction steps, expected and
   observed behavior, and a minimal proof of concept when one is safe to share.

Do not open a public issue containing credentials, encryption material,
personally identifiable information, private messages, audio, or an unpatched
exploit.

Maintainers will acknowledge a report, assess scope and severity, coordinate a
fix and release, and credit the reporter when requested and appropriate. A
cryptographic failure must fail closed; PTT Talk never falls back to plaintext.

## Operational incidents

Instance-specific access, account, delivery, and availability incidents should
first go to that instance's administrator. Privacy-redacted support reports may
be attached to a private security report when the issue appears to affect the
software rather than one deployment.
