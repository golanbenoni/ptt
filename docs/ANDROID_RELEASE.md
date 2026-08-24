# Android release and FCM wake setup

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

On a Google Play-enabled device, sign in, tap **Stay connected**, and confirm
the admin console reports FCM configured. Force-stopping the app intentionally
disables delivery until the user opens and arms it again; reboot also requires
an explicit re-arm.
