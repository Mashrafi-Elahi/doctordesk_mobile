// Read-only audit of the live Firestore shape. Never writes.
//
//   node scripts/audit_firestore.js            # field usage per collection
//   node scripts/audit_firestore.js --claimed  # claimed doctors in detail
//
// Prints which fields each collection uses and how often, so duplicate or
// dead fields are visible before a migration.

const admin = require('firebase-admin');
const { initializeAdmin } = require('./lib/admin_init');

const COLLECTIONS = [
  'doctors', 'chambers', 'chamber_operators', 'operatorAssignments', 'appointments',
  'queues', 'doctor_slots', 'active_bookings', 'chamber_day_overrides', 'chats',
  'notifications', 'reviews', 'users', 'admins', 'journal',
];

function typeOf(v) {
  if (v === null) return 'null';
  if (Array.isArray(v)) return 'array';
  if (v && typeof v.toDate === 'function') return 'timestamp';
  return typeof v;
}

async function fieldUsage(db, name, sample) {
  const snap = await db.collection(name).limit(sample).get();
  const usage = new Map();
  for (const doc of snap.docs) {
    for (const [k, v] of Object.entries(doc.data())) {
      const u = usage.get(k) || { n: 0, types: new Set() };
      u.n++;
      u.types.add(typeOf(v));
      usage.set(k, u);
    }
  }
  const count = (await db.collection(name).count().get()).data().count;
  console.log(`\n## ${name}  (${count} docs, sampled ${snap.size})`);
  [...usage.entries()].sort((a, b) => b[1].n - a[1].n).forEach(([k, u]) => {
    console.log(`  ${k.padEnd(28)} ${String(u.n).padStart(4)}  ${[...u.types].join('|')}`);
  });
}

async function claimed(db) {
  const snap = await db.collection('doctors').where('claimedByUid', '!=', null).get();
  console.log(`\n## claimed doctors (claimedByUid set): ${snap.size}`);
  for (const d of snap.docs) {
    const x = d.data();
    console.log(`  ${d.id}  name="${x.name}"  claimStatus=${x.claimStatus}  isClaimed=${x.isClaimed}` +
      `  verification=${x.verificationStatus}/${x.isBmdcVerified}  hidden=${x.hidden || x.isHidden || false}` +
      `  deleted=${x.isDeleted || false}  chambers=${(x.chambers || []).length}`);
  }
  const byStatus = await db.collection('doctors').where('claimStatus', '==', 'claimed').get();
  const missing = byStatus.docs.filter((d) => !d.get('claimedByUid'));
  console.log(`  claimStatus=='claimed' docs: ${byStatus.size}; of those without claimedByUid: ${missing.length}`);
  missing.forEach((d) => console.log(`    ${d.id} "${d.get('name')}"`));
}

(async () => {
  initializeAdmin(admin);
  const db = admin.firestore();
  if (process.argv.includes('--claimed')) {
    await claimed(db);
  } else {
    for (const c of COLLECTIONS) {
      try {
        await fieldUsage(db, c, Number(process.env.SAMPLE || 300));
      } catch (e) {
        console.log(`\n## ${c}: ${e.message}`);
      }
    }
  }
  process.exit(0);
})().catch((e) => { console.error(e); process.exit(1); });
