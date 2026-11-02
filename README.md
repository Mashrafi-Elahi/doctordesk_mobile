# DoctorDesk Mobile

DoctorDesk is an end-to-end healthcare coordination platform built with Flutter and Firebase. It bridges the gap between patients, specialist medical practitioners, chamber operators, and administrative verification staff through real-time queues, verified credentials, and appointment lifecycle management.

---

## 👥 Supported Roles & Portals

1. **Patient (Blue Theme):** Browse verified doctors, filter by speciality and accessibility, request appointments, write verified reviews, track live queue positions, and maintain health journals.
2. **Doctor (Green Theme):** Manage multiple chamber locations, assign desk operators, review patient queue, accept/reschedule requests across chambers, and communicate via unlocked follow-up care chats.
3. **Chamber Operator (Orange Theme):** Manage chamber desk queue, process incoming patient requests, assign time slots and sequential queue numbers, mark visits complete.
4. **Administrator (Dark Purple Theme):** Review doctor verification submissions against BM&DC registry records, handle doctor profile claims, and inspect audit logs.

---

## 🛠 Tech Stack

- **Frontend:** Flutter SDK (Dart) with Material 3 dynamic role-theming
- **Authentication:** Firebase Authentication (Email/Password, Google OAuth, Phone OTP)
- **Database & Realtime Sync:** Cloud Firestore with strict multi-role composite indexes
- **Security & Data Isolation:** Cloud Firestore & Storage Security Rules with emulator test suite
- **Storage:** Firebase Cloud Storage for medical documents and prescription verification
- **Search & Geospatial:** Geofire prefix matching & geospatial chamber discovery

---

## ⚙️ Setup & Installation

1. **Clone the repository:**
   ```bash
   git clone https://github.com/Mashrafi-Elahi/doctordesk_mobile.git
   cd doctordesk_mobile
   ```

2. **Install Flutter dependencies:**
   ```bash
   flutter pub get
   ```

3. **Firebase Configuration:**
   - Ensure the project is linked with Firebase project `docdesk-1e4cc`.
   - Android configuration: Place `android/app/google-services.json`.
   - Deploy cloud security rules and indexes:
     ```bash
     firebase deploy --only firestore:rules,firestore:indexes --project docdesk-1e4cc
     ```

4. **Running Firestore Security Rules Tests:**
   The test suite runs against the local Firestore Emulator with `@firebase/rules-unit-testing`:
   ```bash
   firebase emulators:exec --only firestore "npm --prefix test/emulator test"
   ```

5. **Run the App:**
   ```bash
   flutter run
   ```

---

## 🗓 The Booking Flow in 5 Lines

1. **Request:** Patient selects a doctor, chamber, and preferred date in the Patient portal; write locks the slot in `active_bookings`.
2. **Routing:** System queries chamber operators—if assigned, exclusively notifies operators (`handledBy: 'operator'`); if none, exclusively notifies doctor (`handledBy: 'doctor'`).
3. **Acceptance:** Operator or doctor opens the Requests tab, taps **Accept**, and chooses from calculated free time slots.
4. **Queue Assignment:** Firestore transaction confirms appointment, assigns sequential queue position (`queuePosition`), and notifies patient.
5. **Completion:** Desk marks consultation done, releasing the active booking lock and unlocking follow-up chat.

---

## ⚠️ Known Limitations

1. **Manual BM&DC Verification:** BM&DC verification uses an in-app administrative web review with automated field prefilling; no official automated BM&DC public API exists.
2. **Not Endorsed by BM&DC:** The verification badge signifies an administrative registry check on a specific date, not an official endorsement or direct API integration.
3. **No Payment Gateway:** Consultations currently use chamber pay-on-arrival (no live payment gateway integration).

---

## 📄 Documentation

- [`docs/SRS.md`](docs/SRS.md) — requirements specification
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — architecture guide
- [`docs/SCHEDULING_ALGORITHM.md`](docs/SCHEDULING_ALGORITHM.md) — per-doctor daily queue and appointment lifecycle
- [`docs/adr/`](docs/adr/) — architecture decision records
- [`docs/KNOWN_ISSUES.md`](docs/KNOWN_ISSUES.md)
- [`docs/DEMO_SCRIPT.md`](docs/DEMO_SCRIPT.md)

Project history (old progress logs, reviews, one-off migration scripts) lives in git history.

---

## 🧰 Admin Scripts (`scripts/`)

Node scripts for data and account maintenance (`npm --prefix scripts install` first). Admin scripts need a service-account key (never committed):

- `npm --prefix scripts run bundle:doctors` — rebuild `assets/data/bundled_doctors.json` (`build_bundled_doctors.js`)
- `npm --prefix scripts run setup:accounts` — dry-run demo role account setup; add `-- --apply` to write (`setup_accounts.js`)
- `npm --prefix scripts run bootstrap:owner` — grant the owner admin role (`bootstrap_owner_admin.js`)

`doctordirectory/bundled_doctors_backup.json` is a backup of the bundled directory data.
