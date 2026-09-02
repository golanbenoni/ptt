# Android release and FCM wake setup

These instructions apply to the **0.1.23 (26)** private-beta release candidate.
The Android client supports API 26+ and targets API 36. A successful bundle
build is not release proof; the exact commit must also pass the physical voice,
eight-hour screen-off soak, push-readiness, and store-readiness gates described
in [`CURRENT_STATE.md`](CURRENT_STATE.md).

PTT Talk uses Firebase Installation ID-based Cloud Messaging only as an opaque
wake signal. FCM never carries account identifiers, channel names, keys, or
voice; the foreground session downloads per-device encrypted mailbox items from
the self-hosted control plane.

Put release signing and Firebase Android app values in
`~/.ptt_release/android.env` (or point `PTT_RELEASE_ENV` at another private
file):

```bash
export PTT_UPLOAD_STORE_FILE=/private/path/ptt-upload.jks
export PTT_UPLOAD_STORE_PASSWORD='...'
export PTT_UPLOAD_KEY_ALIAS=ptt-upload
export PTT_UPLOAD_KEY_PASSWORD='...'
export PTT_FIREBASE_APPLICATION_ID='1:1234567890:android:...'
export PTT_FIREBASE_API_KEY='...'
export PTT_FIREBASE_PROJECT_ID='your-project'
export PTT_FIREBASE_SENDER_ID='1234567890'
```

The app initializes Firebase from these generated `BuildConfig` values, so a
tenant-specific `google-services.json` is not required or committed. The
server-side service-account JSON belongs only in the Helm secret
`secrets.fcmServiceAccountJson`; it must never be packaged in the app.

Build and verify the Play bundle with:

```bash
./scripts/android-release.sh
```

The script verifies the JAR signature and writes an adjacent SHA-256 checksum.
Keep the `.aab` and `.sha256` together in the release evidence bundle.

Before publishing, also run:

```bash
./scripts/validate-firebase-client-config.sh
./scripts/verify-production-push-readiness.sh
node scripts/verify-store-readiness.mjs
./scripts/verify-release-gates.sh
```

On a Google Play-enabled device, sign in, tap **Stay connected**, and confirm
the admin console reports FCM configured. Force-stopping the app intentionally
disables delivery until the user opens and arms it again; reboot also requires
an explicit re-arm.
