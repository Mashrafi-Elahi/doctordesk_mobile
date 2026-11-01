// Firestore field cleanup. Dry run by default.
//
//   node scripts/migrate_cleanup.js            # report only
//   node scripts/migrate_cleanup.js --apply    # fill missing/inconsistent fields (no deletes)
//   node scripts/migrate_cleanup.js --apply --prune
//                                              # also delete junk fields and dead docs
//
// 1. users: literal top-level keys like "roles.isOperator" (written by set()
//    with dotted keys) -> copied into the real roles map when that value is
//    missing; --prune removes the literal keys. Conflicts are only reported.
// 2. doctors: claimedByUid set but claimStatus/isClaimed disagree -> claimed.
// 3. queues: old {chamberId}_{date} docs without doctorId (pre per-doctor
//    queue) -> --prune deletes those from past days.

const admin = require('firebase-admin');
const { initializeAdmin } = require('./lib/admin_init');

const APPLY = process.argv.includes('--apply');
const PRUNE = APPLY && process.argv.includes('--prune');

function dhakaDateKey() {
  const d = new Date(Date.now() + 6 * 3600 * 1000);
  return `${d.getUTCFullYear()}${String(d.getUTCMonth() + 1).padStart(2, '0')}${String(d.getUTCDate()).padStart(2, '0')}`;
}

async function users(db) {
  console.log('\n## users: literal "roles.*" keys');
  const snap = await db.collection('users').get();
  for (const doc of snap.docs) {
    const data = doc.data();
    const literal = Object.keys(data).filter((k) => k.startsWith('roles.'));
    if (!literal.length) continue;
    const roles = (data.roles && typeof data.roles === 'object') ? data.roles : {};
    const fill = {};
    for (const key of literal) {
      const role = key.slice('roles.'.length);
      if (roles[role] === undefined) {
        fill[`roles.${role}`] = data[key];
      } else if (roles[role] !== data[key]) {
        console.log(`  CONFLICT ${doc.id}: roles.${role}=${roles[role]} but literal "${key}"=${data[key]} (keeping roles map)`);
      }
    }
    console.log(`  ${doc.id} (${data.email || data.name || ''}): literal=${literal.join(',')}` +
      (Object.keys(fill).length ? ` fill=${JSON.stringify(fill)}` : ''));
    if (APPLY && Object.keys(fill).length) await doc.ref.update(fill);
    if (PRUNE) {
      const args = literal.flatMap((k) => [new admin.firestore.FieldPath(k), admin.firestore.FieldValue.delete()]);
      await doc.ref.update(...args);
    }
  }
}

async function doctors(db) {
  console.log('\n## doctors: claim fields');
  const snap = await db.collection('doctors').where('claimedByUid', '>', '').get();
  const perUid = {};
  snap.docs.forEach((d) => { perUid[d.get('claimedByUid')] = (perUid[d.get('claimedByUid')] || 0) + 1; });
  for (const doc of snap.docs) {
    const d = doc.data();
    if (d.claimStatus === 'claimed' && d.isClaimed === true) continue;
    // One account owning two profiles is a duplicate for an admin to merge,
    // not something to mark claimed automatically.
    if (perUid[d.claimedByUid] > 1) {
      console.log(`  REVIEW ${doc.id} "${d.name}": account ${d.claimedByUid} owns ${perUid[d.claimedByUid]} profiles; left as is`);
      continue;
    }
    console.log(`  ${doc.id} "${d.name}": claimStatus=${d.claimStatus} isClaimed=${d.isClaimed} -> claimed`);
    if (APPLY) {
      await doc.ref.update({
        claimStatus: 'claimed',
        isClaimed: true,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    }
  }
  const orphan = await db.collection('doctors').where('claimStatus', '==', 'claimed').get();
  orphan.docs.filter((d) => !d.get('claimedByUid')).forEach((d) =>
    console.log(`  REVIEW ${d.id} "${d.get('name')}": claimStatus=claimed but no claimedByUid`));
}

async function queues(db) {
  console.log('\n## queues: pre per-doctor docs');
  const today = dhakaDateKey();
  const snap = await db.collection('queues').get();
  for (const doc of snap.docs) {
    const q = doc.data();
    if (q.doctorId) continue;
    const past = String(q.date || '').replace(/-/g, '') < today;
    console.log(`  ${doc.id}: date=${q.date} lastNumber=${q.lastNumber ?? q.lastQueuePosition}` +
      `${past ? '' : ' (today/future, kept)'}`);
    if (PRUNE && past) await doc.ref.delete();
  }
}

(async () => {
  initializeAdmin(admin);
  const db = admin.firestore();
  console.log(APPLY ? (PRUNE ? 'MODE: apply + prune' : 'MODE: apply (no deletes)') : 'MODE: dry run');
  await users(db);
  await doctors(db);
  await queues(db);
  console.log(APPLY ? '\nDone.' : '\nDry run only. --apply fills fields; --apply --prune also deletes.');
  process.exit(0);
})().catch((e) => { console.error(e); process.exit(1); });
