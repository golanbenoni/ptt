# Zello vs ProPTT2 — Android competitive review

> **Historical research snapshot (August 23, 2026).** This file records product
> research that informed PTT Talk; it is not the current PTT Talk feature or
> release specification. See [`../docs/CURRENT_STATE.md`](../docs/CURRENT_STATE.md)
> for the implemented 0.1.21 (24) product.

Purpose: understand both Android clients well enough to rebuild a better PTT app. Based on official APKs, Play Store listings, product docs, developer specs, and release notes (as of 2026-08-23).

## Releases found

| | Zello | ProPTT2 Smartphone | ProPTT2 Embedded |
|---|---|---|---|
| Package | `com.loudtalks` | `com.imptt.proptt` | `com.imptt.proptt.embedded` |
| Version | **7.14.2** (code 7001402) | **11.0.9** (code 565) | **11.0.9** (code 565) |
| Date | Play: 2026-08-03; official APK matches 7.14.2 | 2026-04-06 | 2026-04-06 |
| Size | 96 MB | 105 MB | 79 MB |
| minSdk / targetSdk | 24 (Android 7) / 37 (Android 17) | 21 (Android 5) / 35 | 21 / 35 |
| Main activity | `com.zello.ui.MainActivity` | `com.imptt.proptt.ui.IntroActivity` | `com.imptt.proptt.embedded.ui.IntroActivity` |
| Play Store | [com.loudtalks](https://play.google.com/store/apps/details?id=com.loudtalks) — 100M+ installs, 4.2★, 759k reviews | [com.imptt.proptt](https://play.google.com/store/apps/details?id=com.imptt.proptt) — 100k+ installs, 3.4★, ~540 reviews | Sideload only |
| Official APK | https://zello.com/data/android/latest/zello.apk | https://www.proptt2.com/download/ProPTT2_1109.apk | https://www.proptt2.com/download/ProPTT2_em_1109.apk |

Local copies: `research/apks/`.

Same Zello binary serves consumer (Friends & Family), Zello Work cloud, and Zello Enterprise Server. ProPTT2 smartphone APK serves guest/free/paid consumer, cloud orgs, and on-prem server customers; Embedded is the dedicated-device / kiosk / no-signup sibling.

---

## What these apps actually are

Both are **broadband Push-to-Talk (PoC)** clients: internet walkie-talkies. Not VoIP phone calls, not WhatsApp voice notes.

Shared radio model:

1. User holds a PTT control (on-screen, hardware key, Bluetooth button, VOX).
2. Client acquires a **floor lock** on a channel (half-duplex: one talker at a time, with exceptions).
3. Live compressed audio streams to a server, which fans it out to channel members in near real time.
4. Floor is released; others can talk. History can be replayed later.

That model is the product. Everything else is packaging: contacts vs radio slots, video, maps, SOS, admin, hardware, AI.

### PTT vs “voice message” vs phone

| | Classic radio / IP-PTT | Voice-note apps | Phone call |
|---|---|---|---|
| Timing | Live stream, sub-second to ~1s | Record then send | Bidirectional session |
| Duplex | Half-duplex floor lock | Full async | Full duplex |
| Group | Native 1:N | Awkward | Conference |
| Hands | One button, works screen-off | Open app, hold, send | Answer/dial |
| Offline | Usually fails (Zello now queues) | Queues | Fails |

Zello’s own docs stress: they stream Opus live; they are not Voxer-style store-and-forward. ProPTT2 explicitly sells “full real-time PTT” vs “record and send,” and also ships a delayed **MP3/music-mode** path for half-duplex devices that cannot play and record at once.

---

## Zello — fundamentals

### Positioning

Consumer social radio that grew into the default frontline PTT for retail, logistics, aviation, hospitality. One Android app, three backends:

- **Friends & Family** — public/private channels, contacts, free, ads never added.
- **Zello Work** — private managed network, web admin console, regional servers, 7k–10k concurrent per channel.
- **Enterprise Server** — on-prem, air-gapped.

Scale they claim: ~5M MAU, ~10B messages/month, 99.99% uptime.

### Audio / transport

- Codec: **Opus** (native `libzello.opus.so`). Also AMR (`libzello.amr.so`), SoundTouch, a neural net (`libzello.rnn.so` — noise/VAD), **WebRTC** (`libzello.webrtc.so`, `libjingle_peerconnection_so.so`).
- Control plane: proprietary low-latency protocol over **UDP with TCP fallback**. Advanced setting “Use TCP only” trades latency for NAT reliability. TLS 1.2/1.3 on control; AES-256 on audio (Work).
- Public **Channel API** (subset): WebSocket JSON control + binary Opus packets (`start_stream` / binary frames / `stop_stream`). Not the full native client protocol.
- Keepalive tunable; “wake device to stay connected” vs battery.
- Recent: live playback recovery on packet loss (v7.9), faster reconnect after brief drops (v7.7), offline **queued channel messages** (v7.14, admin-gated beta).

### Conversation model

- **1:1 contacts** with presence (Available / Busy / Solo / Standby / Offline). Solo mutes others and dumps them to history.
- **Channels**: Team (always on, members auto-contact), Dynamic (join/leave), Hidden, Dispatch (queue → 1:1 with dispatcher).
- **Ad-hoc channels**: on-the-fly groups from contacts.
- Multiple channels can be connected; audio from all plays unless you disconnect.
- Default half-duplex. Interruption exists (QuickConnect channels reject interrupt incorrectly was a 7.3 bug — so interrupt is a real feature).
- Recents + History + Talk screen. Homescreen widget. Overlay/floating PTT. Car mode.

### Media besides voice

- JPEG images, text (Quick Reply templates in 7.14), location pins.
- **No live video PTT.** Camera is for photos/QR sign-in, not walkie video.
- Transcriptions + live translation (Work Plus/Enterprise). AI summaries. Ella AI assistant (knowledge-base Q&A, can be bound to a hardware multifunction key).
- Emergency / SOS: 10s prioritized audio + location to a preconfigured channel. Silent send (NY retail worker safety). Silent receive. Open-mic detection (auto-end silent TX).

### Hardware (this is Zello’s real moat)

APK intent filters cover a large dedicated-device zoo: Sonim, Kyocera, RugGear, Honeywell/Zebra (`com.symbol.button.*`), Kodiak, Runbo, Bittium, Apollo, Elektrobit, plus generic `android.intent.action.PTT.down/up` and `com.zello.ptt.down/up`. USB-C CDC accessories with a documented 2-byte keycode protocol (PTT, SOS, replay, channel knob, status toggle). BLE accessory table in the APK lists **74** named buttons (Jabra, BlueParrott/VXi, 3M Pro-Comms, ECOXGEAR, Zello Button, PTT-Z, etc.).

Also: shared-device shift login, MDM, Microsoft SSO, Imprivata, YubiKey, IMEI auto-login on some rugged phones, QR from admin console.

### Android implementation notes

- 6 dex files, Kotlin/Java, 103 activities, foreground `com.zello.ui.Svc` + `com.loudtalks.client.ui.Svc` + `CallService`.
- FCM for wakeups. Widgets. Overlay (`SYSTEM_ALERT_WINDOW`). Ignore battery optimizations. `USE_FULL_SCREEN_INTENT`.
- Local speech: **Vosk** (`libvosk.so`) — on-device STT, likely voice commands / fallback transcription.
- Billing/Adapty (consumer upsell to Work). Maps, Auth, FIDO.
- Native ABIs still include ancient `armeabi` and `mips` — leftover native codec libs.

### What Zello is good at

Live voice at huge scale. Hardware PTT that works screen-off. Presence and channel types that map to real orgs. History + transcription as a search surface. Admin console. “It just works” for one-thumb talk.

### What Zello is bad at

- **No video.** Photos only.
- Background death on Android (Doze, OEM killers, Android 17 “must be foreground to play audio”). Release notes are a graveyard of reconnect, overlay-stuck-in-receive, hardware PTT loops, missed messages after lock.
- Consumer UX is dated vs iOS (Play reviews). Overlap/interruption of 1:1 vs channel audio.
- Radio gateway exists but is not the product; Motorola WAVE / LMR integration is weaker than ProPTT2’s ProGate story.
- On-prem is a separate Enterprise Server, not the default.

---

## ProPTT2 — fundamentals

### Positioning

Korean IMPTT product: **video IP-PTT platform**, sold as server package + cloud ASP + consumer app + SDK + RoIP gateway. Android is one client of a whole radio-replacement stack. Play Store presence is small; the money is B2B (security, patrol, construction, disaster, logistics).

### Product family (same protocol, different shells)

| Client | Role |
|---|---|
| Smartphone app | Radio-like UI: big lock button, A/B/C + 1:1 **slots**, cover open/closed |
| Embedded app | Full-screen hold-to-talk, kiosk, no-signup APK, dedicated PTT phones, watches, in-vehicle |
| Wear | PTT button + replay + chat |
| Upload app | Bodycam (Hytera VM780, SC580, 4Fact ST20) + PTT |
| Windows PC | Dispatcher: 64 channels, 16 live videos, map, batch TX, interrupt |

### Audio / video / transport

Native libs tell the stack:

- Opus encode/decode
- **Codec2** (2.4 kbps MicroNB — satellite)
- H.264 + H.265 decoders, FFmpeg `libavcodec-57`
- `libJustVoice.so` + `libDenoiser.so` (AI noise / howling)
- UVC: `libUVCCamera.so`, `libusb100.so`, `libuvc.so`
- SQLCipher
- MP4 muxers for upload/bodycam

Docs:

- Dual audio mode: **VoIP full-duplex** vs **MP3/music half-duplex** (Android/Embedded only). Music mode exists because many PTT phones cannot capture and play simultaneously.
- Quality ladder: Full HD 48 kHz/96 kbps → HD 24/48 → 16 kHz 32/16 → 8 kHz 8 → VBR ~4–6 → Codec2 2.4.
- Transport: **TCP + UDP + multicast at once**; pick at login from network. PLC, adaptive jitter buffer, AEC, VAD, SAD (scratch), LPF, software mix.
- Signaling: own **IMPTTP** plus SIP/RTSP for radio/CCTV. Provisioning server issues a token, then PTT server.
- Floor types: normal lock, **competitive lock** (queue next TX), **master lock** (owner/dispatcher talks over others, no TOT), **interrupt**, **emergency lock**.
- Multi-channel: max **3** 1:N + unlimited 1:1 (vs Zello’s much larger simultaneous channel set on Work).
- TOT (time-out timer) shown on the talk UI.

### Conversation / UI model

This is a **radio**, not a messenger:

- Channel slots A/B/C + dedicated 1:1 slot (hardware-knob mental model).
- Status pane: CH number, TOT, member count, record/lock/encrypt/location icons, network+audio graphs, last locker avatar.
- Hold-to-talk lock button with states: standby / TX (cyan) / RX / requesting / interrupting (red) / disconnected.
- Video PTT is a mode on the same lock (front/rear camera).
- Separate **Video Share**: live HD/FHD scene stream while voice PTT and chat continue. UVC webcam. Receiver can record. Description/preset phrases (server 9.1+).
- Chat is IM inside the channel, plus 1:1 chat without joining.
- History is per-channel replay of voice/video PTT with location pins.
- Guest demo channels without signup.

### Safety / enterprise extras Zello does not really do on-device

- SOS + Alert (admin web)
- **Man-down / emergency detection** activities in the APK
- Indoor location: **AltBeacon**
- IMEI / SSAID / phone-number binding
- Mobile-data-only (block Wi-Fi)
- DNS server detection / “Setup host” for on-prem
- Settings lock (password the PTT config so field users cannot change it)
- Device provisioning via `ProPTT2.ini` (kiosk, non-screen, auto-login, keycode map, Hytera/Inrico/Telo ini samples)
- Chromecast (`play-services-cast`)
- Organization tree

### Radio interoperability

**ProGate** RoIP gateway: FRS/UHF/VHF/TRS ↔ IP-PTT. Multi-ProGate bridge of analog channels into one IP channel. SIP GW to IP-PBX. This is a first-class product, not an afterthought.

### What ProPTT2 is good at

Video + voice on the same floor. Dedicated-device UX (slots, kiosk, screen-off PTT, whole-screen hold). On-prem you actually own. Radio bridging. Codec2 for bad links. Dispatcher PC with many video tiles.

### What ProPTT2 is bad at

- Tiny consumer footprint, dated UI (2015-era radio skin), 3.4★.
- iOS PTT in background is officially broken (Apple battery policy); they paused iOS support.
- Scale per channel (cloud: 1k users / 100 channels; app service 500 / 30) is a different universe from Zello’s 7k–10k.
- Dual MP3/VoIP is a hardware workaround that leaks into UX.
- Signup/email verification and connection issues in Play reviews.
- Facebook login dead since 6.x but still in the manual.
- GCM listener still in the APK (`PTTGcmListenerService`) — old push stack lingering beside modern APIs.

---

## Side-by-side

| Capability | Zello 7.14.2 | ProPTT2 11.0.9 |
|---|---|---|
| Live voice PTT | Yes, Opus, UDP/TCP | Yes, Opus + Codec2, TCP/UDP/multicast |
| Half-duplex floor | Default | Default + competitive queue |
| Full duplex | Not the model | VoIP mode; master PTT in 1:N |
| Video PTT | No | Yes (lock-button video) |
| Continuous video share | No | Yes, FHD, H.264/H.265, UVC |
| Text | Yes + Quick Reply | Channel + 1:1 IM |
| Images | JPEG | Images + files |
| Location | Share + live tracking (Work) | Share-on-PTT + channel map + indoor beacon |
| History | Local + Message Vault (cloud, 2y) | Local auto-delete; server recording on Enterprise |
| Transcription / translation | Work Plus: 100+ langs | Speech-to-text on chat only (Android) |
| AI assistant | Ella + digests + summaries | Noise reduction only |
| SOS / emergency | 10s priority + location; silent modes | SOS, alerts, man-down |
| Dispatch | Dispatch Hub + call queue channels | PC client 64 ch / 16 videos; master PTT |
| Public social channels | Yes, up to ~6k listed on Play | Guest demo + search/subscribe |
| Contacts | First-class 1:1 | Friends; 1:1 is a channel slot |
| Multi-channel | Many (API: 100 Work) | 3 × 1:N + unlimited 1:1 |
| Hardware PTT | Very deep (USB-C spec, 74 BLE, many OEM intents) | Deep on rugged/PoC phones, ini provisioning, Wear |
| Screen-off PTT | Yes, constantly patched | Yes, marketed; floating button + widget |
| Kiosk / shared device | Zello Kiosk + shift accounts | Embedded kiosk service, settings lock |
| On-prem | Enterprise Server | Server Mini / Standard / Enterprise (Windows+Linux) |
| Radio (LMR) | Gateway exists | ProGate first-class |
| SDK | Native iOS/Android/RN (Work); Channel API WS | Free iOS/Android/Windows/Linux SDK + OpenAPI + plugins |
| Consumer scale | 100M+ installs | 100k+ |
| Encryption | AES-256 media, TLS control; 1:1 E2EE unless Vault | TLS + AES128/ARIA256/SHA512; optional E2EE |
| Offline | Queue channel messages (beta) | Poor; “full real-time” assumption |
| Wearables | Limited vs ProPTT2 | Android Wear + Apple Watch as PTT |

---

## Android engineering comparison (from the APKs)

**Zello** is a modern-ish single-app: Kotlin, 6 dex, WorkManager, FCM, WebRTC, Compose-adjacent UI packages (`com.zello.ui.*`), SSO, plugins. Still one giant `Svc` foreground service — the classic PTT “never die” process.

**ProPTT2** is an SDK-cored radio (`com.imptt.propttsdk.core.PTTControllerService`) with two UIs. Extra: MusicService (MP3 mode uses Android media session — that is why half-duplex playback can use the music path), FloatWindow, KioskService, Beacon, Cast, WearableListener. Activities explode into per-setting screens (VoicePTT, VideoPTT, UVC, deletion cycles, option lock). That is a 2014 Android information-architecture, not a 2026 one.

Both request the same dangerous core: `RECORD_AUDIO`, `CAMERA`, location, Bluetooth connect/scan, `FOREGROUND_SERVICE_*`, `SYSTEM_ALERT_WINDOW`, `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`, boot completed. ProPTT2 also wants background location, multicast Wi-Fi, privileged phone state, documents. Zello wants contacts, nearby Wi-Fi, full-screen intent, ad ID.

Neither is a mesh/offline-first radio. Both are client–server.

---

## Where both fail (opportunity)

1. **Android background audio is the war.** OEM Doze, Android 14+ FGS types, Android 17 foreground-to-play. Zello’s changelog is mostly this. A new app that treats “still alive after 8 hours in a pocket on a cheap Samsung” as the #1 KPI wins operations deals.

2. **UX split is fake.** Users want Zello’s recents/contacts *and* ProPTT2’s one-hand radio (slots, giant lock, channel knob). Nobody wants 80 settings activities or a 2012 orange talk button as the only options.

3. **Video is table-stakes for security/patrol/construction; voice-only is table-stakes for retail/logistics.** Shipping one without the other cedes a vertical.

4. **Floor control is underspecified in consumer Zello** (overlap complaints) and over-gadgeted in ProPTT2 (master / competitive / interrupt / TOT). Need: default half-duplex, optional barge-in with role, optional full-duplex 1:1, visible who’s talking, no mystery lock.

5. **Hardware PTT should be a plugin map**, not 50 hardcoded OEM intents. Both apps copy-paste manufacturer broadcasts. A better app: open accessory profile (BLE GATT + USB CDC + keycode + Android broadcast) plus a maintained device pack.

6. **On-prem vs cloud should be the same binary and protocol**, with local LAN discovery (ProPTT2 DNS/auto-search is the right idea; Zello’s three backends confuse users).

7. **History + search.** Zello is moving here (transcription, vault, AI digest). ProPTT2 history is a tape recorder. The rebuild should assume every TX is a message with transcript, location, and optional video keyframe.

8. **Don’t pretend to be a social network.** Zello public channels are a growth hack and a moderation/safety hole. ProPTT2 guest demos are enough.

---

## Rebuild recommendation

Build **one Android client** that behaves like a radio in the hand and a modern messenger in history, with video as a mode not a separate app.

### Product shape

- **Talk surface:** one primary channel/contact, giant PTT, speaker/ear, battery/network, who’s talking. Hardware key and BLE work with screen off. Optional A/B/C slots for radio people.
- **Recents + inbox:** missed TX, transcripts, photos, locations, video clips.
- **Channels:** team (always), duty (join for shift), 1:1, ad-hoc, dispatch queue. Roles: talk, listen, barge, dispatch, emergency target.
- **Video:** (a) video-PTT (hold = talk with camera), (b) scene share (one-to-many live, voice continues). Adaptive H.264; H.265 when encoder exists.
- **Safety:** SOS (silent option), man-down as a plugin, not a maze of activities.
- **Admin:** web console + MDM config (managed config / QR). Same app for cloud and customer server.
- **Accessories:** documented intent + USB CDC + BLE; ship profiles as JSON (Zello’s `assets/ble/list.json` is the right pattern).

### Protocol / media (do not copy either proprietary stack)

- Opus 16–48 kHz, 20 ms packets, FEC, PLC, adaptive jitter.
- Codec2 or Opus NB only as a degraded profile for satellite/2G.
- Media over QUIC or SRTP/UDP with ICE; control over QUIC or WebSocket+TLS. Avoid “TCP-only vs UDP” as a user-facing advanced setting — pick automatically.
- Floor: request / grant / deny / preempt, with TOT and priority (SOS > dispatch > master > normal).
- Persist last N minutes locally encrypted; optional org vault.

### Android must-haves (this is where you beat both)

- One microphone FGS + connected-device FGS, not a god-service that also does billing.
- Microphone + audio focus policy that survives Bluetooth HFP/A2DP and wired PTT headsets (Zello “legacy Bluetooth mode” exists because this is hard).
- Boot receiver + `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` + OEM-specific guides (Samsung, Xiaomi, Oppo).
- Widget + tile + overlay PTT, all mapping to the same session.
- VOX with VAD that does not false-trigger (open-mic detection from Zello 7.7 is worth copying).
- Do not use the music player for PTT (ProPTT2 MP3 mode). Use AudioRecord/AudioTrack + a proper duplex engine.

### What to steal

From **Zello:** Talk/Recents/History IA; presence; dispatch queue; silent SOS; offline queue; transcription as default; accessory JSON; keep-alive that actually stays up; shared-device shifts.

From **ProPTT2:** Slot + lock-button radio UI; video PTT + scene share; master/competitive floor; device ini provisioning; kiosk; RoIP as a gateway product; Codec2 profile; in-channel network/audio meter (users trust meters).

### What not to rebuild

- Public social channels as the homepage.
- 100 Activities for settings (one settings graph).
- Facebook login, GCM leftovers, Cast unless a customer asks.
- Dual “MP3 vs VoIP” user toggle.
- Shipping mips/armeabi natives in 2026.

### Suggested MVP vs later

**MVP:** Android voice PTT, 1:1 + channels, history, hardware/BLE PTT, overlay, presence, cloud server, Opus/UDP+QUIC. Beat Zello on “still connected in pocket.”

**v1:** Video PTT, transcripts, SOS, admin console, QR/MDM login, maps.

**v2:** Scene share, dispatch, on-prem, RoIP gateway, Wear, kiosk/embedded APK flavor from the same codebase.

---

## Source map

- APKs: `research/apks/`
- Manifest dumps: `research/extracted/*_manifest.json`
- Zello BLE profiles: `research/extracted/zello/assets/ble/list.json`
- ProPTT2 intro + smartphone + embedded manuals: `research/docs/`
- Zello Channel API: https://github.com/zelloptt/zello-channel-api/blob/master/API.md
- Zello Android notes: https://zello.com/release-notes/android/
- ProPTT2 client/media/network: https://dev.proptt2.com/docs-client-overview.html , docs-media-audio.html , docs-net-overview.html
