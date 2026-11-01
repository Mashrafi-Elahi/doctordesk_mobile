# ADR-001: Canonical Firestore data model on the free (Spark) plan

**Status:** Accepted (parts 1–3 implemented; parts 4–6 scheduled)
**Date:** 2026-11-02
**Deciders:** Mashrafi Elahi (owner)

## Context

DoctorDesk runs on Firebase Spark: Firestore and Auth only. Cloud Storage
is not available on this project and scheduled Cloud Functions need Blaze,
so the client and admin scripts must do everything.

A read-only audit (`node scripts/audit_firestore.js`, 2 Nov 2026) of the
live database found:

| Collection | Docs | Problem |
|---|---|---|
| doctors | 11,054 | Three claim fields that disagreed (`isClaimed`, `claimStatus`, `claimedByUid`); `bmdcNumber` + `bmdcRegNumber`; `isBmdcVerified` + `verificationStatus`; three search fields (`searchText`, `searchPrefixes`, `searchTokens`) on every doc; one account owning two profiles (Nuzhat Saima) |
| chambers | 305 | 302 legacy flat docs (`doctorId`, `hospitalName`, `location`, `id`); 3 canonical docs still carrying `aliases`, `members`, `doctorIds`, `operator*`, `hasOperator`, `isAccessible` |
| users | 19 | Literal top-level keys named `roles.isOperator` etc. (from `set()` with dotted keys in `setup_accounts.js`); `chamberCount`, `operatorAssignments`, `assignedChambers` duplicate what `chamber_operators` says |
| queues | 6 | 4 pre per-doctor docs (`{chamberId}_{date}`, no `doctorId`) |
| notifications | 76 | `recipientId` duplicates `userId` |
| reviews | 12 | `patientUid` duplicates `userId`; `userName` duplicates `raterName`; `proofImageUrl` points at Storage |

Forces: a few hundred real users at most, a 6,000-doctor bundled directory
that must work offline, free-tier read/write quotas (50k reads/day), and
an owner who tests on a real Android phone after each change.

## Decision

1. **One source of truth per fact; everything else is derived in the app.**
   - Claimed ⇔ `claimedByUid` is a non-empty string. `claimStatus` /
     `isClaimed` are kept in sync by migration and by every claim write,
     and are only used for queries. `Doctor.isClaimedProfile` is the
     single reader.
   - Verified ⇔ `verificationStatus ∈ {verified, checked_found}`;
     `isBmdcVerified` mirrors it.
   - Listing order is computed (`Doctor.listRank`): claimed + verified,
     claimed, verified, rest. It is not stored, so it never goes stale.
2. **Queues are per chamber + doctor + day** —
   `queues/{chamberId}_{doctorId}_{yyyyMMdd}` with `lastNumber`,
   `currentServing`, `currentAppointmentId`, `waitingTokens`,
   `waitingCount`. Appointment status moves only along
   `QueueService.transitions`, mirrored by `allowedNext()` in
   `firestore.rules`.
3. **Roles live only in the `users/{uid}.roles` map**; no dotted literal
   keys. Scripts nest dotted keys before `set()`.
4. **Chamber membership** moves from `chamber_operators` +
   `users.operatorAssignments` to `chambers.operatorUids[]` and
   `chamberDoctors/{chamberId}_{doctorId}` (as specified in the cleanup
   plan, Phase 1).
5. **Duplicate fields are dropped after the code stops reading them**:
   `bmdcRegNumber`, `searchText`, `searchTokens`, `notifications.recipientId`,
   `reviews.patientUid`, `reviews.userName`.
6. **Images without Cloud Storage** (see options below): reviews carry no
   images; health documents stay on the device; a prescription the patient
   chooses to send to their doctor is compressed and stored inline in
   Firestore.

## Options Considered (images)

### Option A: Inline in Firestore (compressed JPEG, base64)
| Dimension | Assessment |
|-----------|------------|
| Complexity | Low — no new service |
| Cost | Free; counts against Firestore storage (1 GiB free) |
| Scalability | ~1 MiB doc limit → one image per doc, ≤ 1024 px, quality ~60 (≈100–250 KB) |
| Team familiarity | High — same rules language and SDK |

**Pros:** works today on Spark; access control is the existing chat rules;
offline cache for free.
**Cons:** every read of the attachment doc pays the full image size; not
for galleries or video.

### Option B: Third-party image host (Cloudinary / ImgBB free tiers)
| Dimension | Assessment |
|-----------|------------|
| Complexity | Medium — API keys, signed uploads |
| Cost | Free tier, then paid |
| Scalability | Good |
| Team familiarity | Low |

**Pros:** real CDN, large files.
**Cons:** medical images leave Firebase; unsigned upload keys in an APK are
public; access control is separate from Firestore rules.

### Option C: Upgrade to Blaze and use Cloud Storage
| Dimension | Assessment |
|-----------|------------|
| Complexity | Low — code already exists |
| Cost | Needs a billing account; small usage stays within free quotas |
| Scalability | Best |
| Team familiarity | High |

**Pros:** existing upload code works unchanged; also unlocks the queue
watcher Cloud Function.
**Cons:** requires a card on file — the owner has ruled this out for now.

### Option D: No sharing; images stay on the device
**Pros:** zero cost, zero privacy risk. **Cons:** a doctor never sees the
prescription.

## Trade-off Analysis

Option A is the only one that ships now without billing and keeps medical
images inside Firebase rules. Its size limit is acceptable because a
prescription photo at 1024 px / q60 is well under the 1 MiB document
limit, and sharing is one-image-at-a-time by nature. Option C remains the
upgrade path: when billing is enabled, attachments can move to Storage by
swapping the `data` field for a `url` without changing the chat UI.

## Consequences

- Easier: one obvious field per fact; listing order and claim checks are
  in one place; queue numbers can't collide between doctors.
- Easier: no feature depends on Storage, so nothing fails on Spark.
- Harder: Firestore reads get heavier for chats with image attachments —
  load attachments lazily, never in list queries.
- Revisit: when billing is enabled, move attachments to Storage and deploy
  `functions/queueWatcher`.

## Action Items

1. [x] Per-doctor daily queue + lifecycle rules (`QueueService`, `firestore.rules`).
2. [x] Claim field sync for single-owner profiles (`scripts/migrate_cleanup.js --apply`).
3. [x] Stop writing dotted role keys (`scripts/setup_accounts.js`).
4. [x] Remove review image upload (Storage unavailable).
5. [ ] Owner runs `node scripts/migrate_cleanup.js --apply --prune` to delete
       literal `roles.*` keys and past legacy queue docs.
6. [ ] Merge the duplicate Nuzhat Saima profiles (admin decision: keep
       `doctor_uHlqUgF07vZ8Ie4z54KinN9i0Li1`, hide `doctor_nuzhat_saima`).
7. [ ] Phase 1: `chamberDoctors` + `chambers.operatorUids`, drop
       `chamber_operators` / `users.operatorAssignments` / `chamberCount`.
8. [ ] Stop reading then drop `bmdcRegNumber`, `searchText`, `searchTokens`,
       `notifications.recipientId`, `reviews.patientUid`, `reviews.userName`.
9. [ ] Chat attachment: `chats/{chatId}/attachments/{id}` with compressed
       base64 `data`, readable by chat participants only; feed and claim
       certificate uploads disabled or switched to the same pattern.
