# Core services issue report: Google Sign-In, chat, AI, error messages

Date: 1 Nov 2026 · Build: Android release APK built on the Mashrafi's-project Mac · Firebase project `docdesk-1e4cc`

## Summary

| Service | Status | Root cause | Who can fix |
| :--- | :--- | :--- | :--- |
| Firebase (Auth email/password, Firestore, rules) | **Working** | — (verified live tonight with all four roles) | — |
| Google Sign-In, Android | **Broken** | Signing key's SHA-1/SHA-256 not registered in Firebase | Project owner, in Firebase console |
| Google Sign-In, iOS | **Broken (crashes)** | iOS app not configured for Google Sign-In | Project owner + code |
| Follow-up chat, first visit | **Working** | — (verified live: "Follow-up Chat Unlocked") | — |
| Follow-up chat, returning patient | **Broken (silent)** | Security rule refuses re-opening an existing chat | Code + rules deploy |
| AI symptom triage (Gemini) | **Probably broken (silent)** | `GEMINI_API_KEY` is not a normal Gemini API key | Project owner |
| Error messages | **Developer text shown to users** | Raw exceptions and setup instructions in the UI | Code |

---

## 1. Google Sign-In on Android: SHA fingerprint missing

**What users see:** *"Google Sign-In is not configured for this Android build. Add this app's SHA-1 and SHA-256 in Firebase Console, download google-services.json again, then rebuild."* (from `lib/widgets/auth_modal.dart:68`).

That message is only shown when Google returns `sign_in_failed` / `ApiException: 10` (DEVELOPER_ERROR), which means the certificate that signed the APK is not registered for the Android app in Firebase.

**Evidence**
- `android/app/build.gradle.kts:35`: the release build is signed with the **debug** key of whatever machine builds it.
- This Mac's debug key:
  - SHA-1 `F0:AB:7B:C0:51:75:64:07:97:0E:9A:ED:7B:71:DC:46:F5:A6:E5:06`
  - SHA-256 `2B:F6:90:DD:70:72:C7:49:18:36:EF:8E:D1:44:04:27:1F:54:B7:81:B6:99:5A:A2:C7:E9:4C:3B:31:E3:EB:A9`
- `scripts/configure_android_google_signin.js` registers only `A1:0F:C4:1C:…:A6:EE`, a different machine's key.
- `android/app/google-services.json` contains no Android OAuth client (`client_type: 1`), only the web client. So when this file was downloaded, no fingerprint was registered at all.

**Fix (Firebase console, ~5 minutes)**
1. Project settings → Your apps → Android `com.doctordesk.doctordesk` → **Add fingerprint**: add the SHA-1 and SHA-256 above (and the teammate's, if they also build).
2. Authentication → Sign-in method: confirm **Google** is enabled.
3. Download the new `google-services.json` into `android/app/`, rebuild, reinstall.

**Longer term:** create a real release keystore (`key.properties` + `signingConfigs.release`), so every machine produces the same signature and you register one fingerprint.

## 2. Google Sign-In on iOS: crashes

- No `GoogleService-Info.plist`, no `GIDClientID`, and no reversed-client-ID URL scheme in `ios/Runner/Info.plist`. The Google SDK throws, and the app aborts.
- `lib/firebase_options.dart` has `iosBundleId: 'com.example.doctordesk'`; the app's real bundle ID is `com.doctordesk.doctordesk`.

**Fix:** register the iOS app in Firebase with the real bundle ID, add `GoogleService-Info.plist`, add the URL scheme, and re-run `flutterfire configure`. Not needed for an Android-only demo.

## 3. Follow-up chat for returning patients: silently not unlocked

**What happens:** the first completed visit between a patient and doctor creates the chat (works). On any **later** visit, "Mark done" succeeds but the chat is **not** re-opened: it stays expired or at its message limit, and the patient gets no new "Follow-up Chat Unlocked" notification.

**Cause**
- `ChatService.unlockChatForCare` (`lib/services/chat_service.dart:15`) writes `chats/{patient_doctor}` with `set(..., merge: true)`. For an existing chat this is an **update** that changes `expiresAt`, `unlockedBy`, `createdAt` and `messageCount`.
- The update rule (`firestore.rules`, `match /chats/{chatId}`) only lets the doctor change `status`, `updatedAt`, `lastMessage` and `messageCount`, and doesn't let an operator update at all. So the write is refused.
- The refusal is caught in `markAppointmentCompletedAndUnlockChat` (`lib/services/firestore_service.dart`) and only logged with `debugPrint`, so nobody sees it.

**Proof:** on the local Firestore emulator with the deployed rules, "first unlock by doctor" passes and "second unlock by doctor for a returning patient" fails.

**Fix options**
- Rules: allow the chat's doctor (and the chamber's assigned operator) to update `expiresAt`, `unlockedBy`, `messageLimit`, `messageCount`, `status`, `lastMessage` and `updatedAt` when re-opening, then deploy the rules.
- Code: stop sending `createdAt` on re-unlock, and show the operator or doctor a clear message if unlocking fails instead of swallowing it.

## 4. AI symptom triage: key looks invalid

- `GEMINI_API_KEY` in `.env` does not have the usual `AIza…` format of a Google AI Studio API key.
- When every Gemini call fails, `GeminiService` returns `null` and only logs it (`lib/services/gemini_service.dart:114-117`), so the AI suggestion card just never appears. Rule-based triage still works.

**Fix:** create a key in Google AI Studio, restrict it to the Android package name + signing SHA-1, put it in `.env`, rebuild. (Also SEC-06 in the SRS: the key ships inside the APK.)

## 5. Developer messages shown to users

| Where | Problem |
| :--- | :--- |
| `lib/widgets/auth_modal.dart:68,73` | Tells users to add SHA fingerprints in Firebase Console and rebuild. |
| `lib/widgets/auth_modal.dart:66-67` | Treats any error message containing "10" as the SHA problem, so unrelated errors get that text too. |
| `lib/screens/main_shell.dart:216` | `Google Sign-in failed: <raw exception>`. |
| 31 snackbars across 13 screens | `Failed to send message: $e`, `Could not accept: $error`, etc. print raw text such as `[cloud_firestore/permission-denied] The caller does not have permission…`. Worst offenders: `operator_desk_screen.dart` (8), `admin_console_screen.dart` (4), `feed_screen.dart` (4), `consultation_management_screen.dart` (3). |
| `lib/widgets/state_views.dart:147-148` | The missing-index message mentions `firebase deploy` (added during the pre-demo polish). |

**Fix:** send every user-facing error through one mapper (`friendlyErrorMessage` in `state_views.dart`, extended with auth codes) that gives plain-language text; keep the raw error in `debugPrint` for developers.

## 6. What was verified working

- Android Firebase config: `lib/firebase_options.dart` matches `google-services.json` (API key, app ID, project, bucket, sender ID).
- Live, on a Galaxy A51 with the release APK: email/password sign-in for all four accounts, booking, operator accept with slot and queue number, doctor start visit / mark done, patient notifications, Past Visits, admin console.
- Firestore rules deployed tonight; 36/36 rules tests pass on the emulator.

## 7. Not verified

- The list of fingerprints currently registered in Firebase: the Firebase CLI's login on this Mac has expired (`firebase login --reauth` to restore).
- Whether the Google provider is enabled in Firebase Authentication.
- A live Gemini response (checked only the key's format, not the key itself).
- The exact on-screen errors on the phone: it was disconnected during this investigation.

---

## Update (1 Nov 2026, 22:50) — fixes applied and live-tested on the dev build

| Area | Result | What changed |
| :--- | :--- | :--- |
| Google Sign-In (Android) | ✅ Works | Fingerprints registered (4 SHA hashes confirmed via CLI); new `google-services.json`. |
| Follow-up chat, first visit | ✅ Works live | Chat unlocked by the operator's Mark done; patient sent a message (20 → 19 remaining). |
| Follow-up chat, returning patient | ✅ Works live | Rules: chat's doctor, admin, or the chamber's assigned operator may re-open with only expiry/limit/count/status/name fields changing. Code: no longer resends `createdAt`; passes the chamber. 7 new emulator tests (43/43 pass). Deployed. |
| Operator Accept | ✅ Works live | Rule now also reads `chamberId` (the chats Accept creates); transaction now does every read before any write (failed in debug builds). |
| Change today's hours (operator) | ✅ Works live | Was crashing on a chamber-only query refused by the rules; now scoped to the doctor and the advisory lookup can't block saving. |
| Inbox after switching accounts | ✅ Works | Inbox now follows sign-in/out instead of showing "Please sign in". |
| Avatar after switching accounts | ✅ Works | Signed-in avatar follows the current account (Google photo shows). |
| Desk snackbars | ✅ Works | Accept/Start/Done/Reject/Reschedule confirmations no longer vanish when the row leaves the list; errors are in plain language. |
| AI triage (Gemini) | ✅ Works (~5 s) | New key works. `gemini-2.5-flash` is retired for new keys; now `gemini-2.5-flash-lite` first, `gemini-3.8-flash` as backup (it often takes > 30 s); 12 s timeout. |
| Operator reroute / waiting counts | ✅ Fixed | Chamber-only queries now include the doctor, so the rules allow them. |

### Still open
- Under the AI card, the doctor suggestions come from the local keyword search and can disagree with the AI specialty (e.g. "burning…" lists urologists).
- 26 other snackbars still print raw exceptions (feed, admin console, consultations, profile); only the desk row actions were converted.
- `auth_modal.dart` still shows the SHA/Firebase-Console text if Google returns error 10 again.
- Not tested live: reschedule, reject, walk-in, close day, feed post/comment, reviews, nearby search (location), document upload/share, paid consultation, doctor chamber/operator management, BMDC verify, language switch, read-aloud.
