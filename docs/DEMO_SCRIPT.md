# DoctorDesk Demo Script

One booking travels through all four roles while every screen updates live from Firestore:

**Patient books → Operator sees it → Operator confirms → Patient gets the confirmation → Doctor runs the visit → Operator queue updates → Admin overview.**

Runtime: about 10 minutes, plus 2–3 minutes of questions.

---

## 1. Cast and devices

| Role | Account | Device | Opens on |
| :--- | :--- | :--- | :--- |
| Patient | Finn (patient account) | Phone 1 | Home tab (blue) |
| Operator | Mahi, `mahi17088@gmail.com` | Phone 2 | Desk tab (orange) |
| Doctor | Dr. Mashrafi Elahi, `mashrafielahi@gmail.com` | Laptop 1 (emulator or Android screen mirror) | Manage tab (green) |
| Admin | `mashrafeelahi8@gmail.com` | Laptop 2 | Admin tab (purple) |
| Spare | Any account, plus the backup screen recording | Laptop 3 | — |

- The chamber in every step is **Bup** (owner: Dr. Mashrafi; operator: Mahi).
- Passwords are on the team sheet, not in this repo.
- After signing in, each account opens in its own main portal (admin → Admin, doctor → Manage, operator → Desk). To act as a patient from a staff account, use **Profile → Active portal → Patient**.
- **Sign in with email and password.** Don't use "Continue with Google": the Android OAuth client is not registered for the demo APK's signing key, so it may fail (SRS OI-01).
- Everyone uses the same Wi-Fi. A phone hotspot is the backup.

Each role has its own colour, so the audience can tell at a glance whose screen they're looking at.

---

## 2. Tonight (must be done before the demo)

1. **Live data check**
   - Mahi signs in → Desk tab shows the **Bup** chamber with no "access" or "index" error.
   - On Bup, Mahi taps **Accept** on a test request → no "Visiting hours not set" error, and the slot picker lists times.
   - If the Desk shows *"This view needs a Firestore index…"*, run `firebase deploy --only firestore:indexes --project docdesk-1e4cc` and wait for the indexes to finish building in the console.
2. **Visiting hours cover demo time.** The desk queue only shows **today's** visits, and Accept offers free slots within Bup's visiting hours. Make sure Bup has hours on demo day that are still open at demo time.
3. **Build one release APK** from the final commit:
   ```bash
   fvm flutter build apk --release
   ```
   Output: `build/app/outputs/flutter-apk/app-release.apk`. Uninstall the old app on both phones, then install:
   ```bash
   adb install build/app/outputs/flutter-apk/app-release.apk
   ```
   Release builds hide the admin console's debug tools (purge, impersonation), so nothing destructive appears on stage.
4. **Full rehearsal** on the real devices (sections 4–5 below), timed.
5. **Clean up after the rehearsal.**
   - Mark the rehearsal booking **done** (or cancel it). A patient can only hold one request per doctor, chamber and day, so an open rehearsal booking blocks Finn from booking again: *"You already have a request for this doctor on this date."*
   - Delete test junk in the Firebase console (for example the "BOOOO BAD DOCTOR" review and the **"Dr. Hello Kitty"** doctor that shows at the top of the admin doctor list).
6. **Clear open requests found in the live test (1 Nov evening).** Bup's Requests list held open requests for tomorrow (2/11) from **Finn**, **Mahi mahi** and the admin account (shown as "Mashrafi Elahi"), plus an admin-account request at **BSL**.
   - Finn's open 2/11 request **will block Finn's live booking on stage**. Cancel it (Finn → Appointments → Cancel) or reject it from Mahi's desk.
   - Reject or cancel the others so Mahi's Requests tab is empty when the demo starts.
   - Optional data tidy-up: the doctor desk lists both **Bup** and an old **Bup Medical** chamber; patient search shows two "Dr. Mashrafi Elahi" entries because the admin account's BSL profile is not actually hidden. In the demo, pick the one whose page shows **Bup, Mirpur Cantonment**.
7. **Backups.** Save the APK, the `.env` and a screen recording of the full flow to the spare laptop and a USB stick.

---

## 3. Thirty minutes before

- [ ] All four accounts signed in and on their start tab (section 1).
- [ ] Phone notifications allowed for DoctorDesk on both phones; Do Not Disturb off.
- [ ] Screen brightness up, auto-lock off, battery above 50%.
- [ ] Finn has **no** open request with Dr. Mashrafi at Bup for today (see the clean-up step above).
- [ ] Mahi's Desk → **Requests** tab is empty or holds only intended items.
- [ ] Recording ready on the spare laptop.

---

## 4. The script

Each step lists **who acts**, **what to tap**, **what the audience should see** and **what to say**.

### Step 1 — Patient finds a doctor and books (Phone 1, Finn, blue)

1. On **Home**, tap the search bar and type a symptom, e.g. `chest pain` (or `buke chap` in Banglish).
   - *See:* a suggestion card naming the specialty (rule-based, instant; Gemini AI steps in for vaguer phrasing).
2. Clear the search and type `Mashrafi`. Tap **Dr. Mashrafi Elahi**.
   - *See:* doctor profile, verified badge, chambers including **Bup**.
3. Tap **Book Appointment**, choose chamber **Bup** and **today's date**, then **Confirm Appointment**.
   - *See:* "Request sent. You will be notified once it is confirmed with a date and time."
4. Open the **Appointments** tab.
   - *See:* the visit under **Upcoming** marked **AWAITING CONFIRMATION**.

> *Say:* "Finn searched by symptom, found a verified doctor and sent a request. Booking writes a lock, so Finn can't double-book the same doctor on the same day."

### Step 2 — Operator sees the request live (Phone 2, Mahi, orange)

1. Mahi is already on **Desk → Bup → Requests**. Don't refresh.
   - *See:* Finn's request appears within a second or two, with no reload.

> *Say:* "Bup has an operator, so the request went to Mahi's desk, not straight to the doctor."

### Step 3 — Operator confirms (Phone 2)

1. On Finn's row tap **Accept**, pick a free time slot, then **Confirm & Assign Queue**.
   - *See:* the request leaves **Requests** and appears in **Today's Queue** with a queue number.

> *Say:* "Accepting runs one database transaction: it claims the slot and hands out the next queue number, so two desks can't give out the same number or time."

### Step 4 — Patient gets the confirmation (Phone 1, Finn)

1. Don't touch anything at first; the bell badge updates on its own. Tap the bell.
   - *See:* **"Appointment Confirmed! 🎉"** with the date, time and queue number.
2. Open **Appointments**.
   - *See:* the badge now reads **CONFIRMED**, with **Queue #N**.

### Step 5 — Doctor runs the visit (Laptop 1, Dr. Mashrafi, green)

1. Open **Manage → Queue Desk → Today's Queue**.
   - *See:* Finn with the same queue number the operator assigned.
2. Tap **Start visit**.
   - *See:* the row shows an **In progress** badge.
3. Tap **Mark done**.
   - *See:* "Appointment marked done; follow-up chat unlocked." The row moves to **Done**.

> *Say:* "Completing the visit releases Finn's booking lock and opens a follow-up chat for 7 days."

### Step 6 — Operator queue updates live (Phone 2, Mahi)

1. Show **Today's Queue**, then **Done**.
   - *See:* Finn already moved from the queue to Done, without a refresh.
2. (Optional) On Phone 1, Finn's **Appointments → Past** now lists the visit, and **Inbox** has the follow-up chat.

### Step 7 — Admin overview (Laptop 2, admin, purple)

1. Open the **Admin** tab (Admin Console).
2. Show the live status card (Firestore connected, latency), then scroll through **Pending Applications** (doctor sign-ups), the doctor list with **Verify on BMDC** (opens the official BM&DC site with the registration number filled in), and **Claims**.
3. Operator applications are reviewed by the doctor, not the admin. To show them, use Laptop 1: **Manage → Chambers**, pending operator applications.

> *Say:* "BM&DC has no public API, so verification is assisted: the app fills in the number, and a human checks the official register and approves."

**Don't tap** *Grant / Revoke*, *Approve*, *Hide*, the red delete icon, *Appoint* or **Start Upload (Batches of 500)** on stage. They write to the live project; Start Upload alone writes 6,048 documents.

### Closing (any device)

> *Say:* "Four people, four devices, one booking. Every screen updated by itself through live Firestore listeners. The booking lock stops double-booking, and the accept transaction stops two people getting the same queue number."

---

## 5. If something breaks on stage

| Symptom | Do this |
| :--- | :--- |
| A screen shows "Something went wrong" | Tap **Retry** on that screen. |
| Request doesn't appear on Mahi's desk after ~5 s | On Phone 2 switch tabs (Requests → Queue → Requests). Still nothing: kill and reopen the app, sign in again. |
| "You already have a request for this doctor on this date" | An earlier booking is still open. Mahi or the doctor marks it done (or Finn cancels it), then book again. |
| Accept shows no time slots | Bup's visiting hours are over for today. Say so, and switch to the recording. |
| "This view needs a Firestore index…" | Index not deployed. Switch to the recording; fix after the demo. |
| Google sign-in fails | Use email and password. |
| Anything else after one restart | Switch to the screen recording on the spare laptop and narrate it. |

---

## 6. Resetting for another run

1. Make sure the last demo booking is **done** or **cancelled**.
2. Patient: pull the app back to **Home**; clear the search box.
3. Operator: back to **Desk → Bup → Requests**.
4. Doctor: back to **Manage → Queue Desk**.
5. Admin: back to the top of the console.
