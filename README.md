# PTT Talk

PTT Talk is an AGPLv3, self-hosted, encrypted push-to-talk system for private
teams. Production voice v1 targets Android first, followed by iOS parity. Each
installation is single-tenant and supports two independently keyed devices per
account.

The repository is under active development. The frozen v1 protocol, Android
and Swift interoperability fixtures, Rust control plane and relay, encrypted
mobile state/history stores, real Opus/SFrame voice clients, administration
console, containers, and K3s Helm chart are present. Android and iOS both expose
the production Talk experience; the legacy tone harness remains debug-only as a
cross-platform protocol fixture.

## Repository layout

- `proto/` and `docs/PROTOCOL_V1.md`: frozen control/media contract.
- `android/`: Kotlin crypto, floor, media, foreground lifecycle, production Talk app, and the
  SQLCipher/Android Keystore persistence module.
- `ios/`: Swift wire and libsignal interoperability packages.
- `native/`: Rust media and SFrame foundations.
- `server/`: Rust control and UDP relay services.
- `admin-web/`: responsive TypeScript instance console.
- `deploy/helm/ptt/`: supported single-tenant K3s installation.

## Local verification

The helper selects JDK 21 and the Homebrew Android SDK when available:

```bash
source scripts/java21-env.sh
./scripts/check-proto-contract.sh
./gradlew :crypto:test :floor:test :media:test :loopback:test :net:test \
  :crypto-persistence:compileDebugKotlin :talkandroid:lintDebug \
  :talkandroid:assembleDebug
cargo test --manifest-path native/Cargo.toml
cargo test --manifest-path server/Cargo.toml --locked
npm ci --prefix admin-web
npm run typecheck --prefix admin-web
npm run build --prefix admin-web
helm lint deploy/helm/ptt -f operator-values.yaml
```

The tone harness remains a protocol fixture and must not be presented as the
production product UI.

The mobile apps now provide live Opus voice, authenticated floor control,
encrypted history, two-device linking/revocation, SOS, background reconnect,
hardware/UI PTT inputs, automatic UDP-to-TLS media fallback, encryption
details, and privacy-redacted support reports. A server-side revocation causes
the affected app to erase its credential and local cryptographic state.

## Self-hosting

See [`deploy/helm/ptt/README.md`](deploy/helm/ptt/README.md) for K3s install,
SMTP, TLS, backup, restore, upgrade, and rollback operations.

See [`docs/ANDROID_RELEASE.md`](docs/ANDROID_RELEASE.md) for Play signing and
privacy-minimized FCM wake configuration.

## License

GNU Affero General Public License v3.0. See `LICENSE`.
