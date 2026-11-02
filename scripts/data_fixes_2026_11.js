// One-time live data fixes, November 2026. Dry run by default.
//
//   node scripts/data_fixes_2026_11.js           # print the plan
//   node scripts/data_fixes_2026_11.js --apply   # write it
//
// 1. Bup + "Bup Medical" become one chamber, "Bup Medical", kept at the
//    canonical id (it holds the live queue, overrides and appointments);
//    Dr. Mashrafi Elahi and Dr. Nuzhat Saima both practise there.
// 2. The admin's BSL chamber and its desk mapping are removed.
// 3. Duplicates hidden: the unclaimed "Dr. Mashrafi" (Bup Medical) profile and
//    the bundled doctor_nuzhat_saima profile (her real one is kept).
// 4. "Dr. Hello Kitty" (a doc id with spaces) becomes Dr. Salsabil at
//    doctor_{ownerUid}; every reference is moved over.
// 5. Old per-appointment desk chats are archived; the doctor's single staff
//    chat is created with their operators.
// 6. Leftovers from the earlier cleanup: literal "roles.*" user keys and
//    pre per-doctor queue docs from past days.
// Removed things are hidden or marked, except the BSL desk mapping and old
// queue counters, which are deleted because the app reads them by existence.

const admin = require('firebase-admin');
const { initializeAdmin } = require('./lib/admin_init');

const APPLY = process.argv.includes('--apply');
const CANONICAL = 'chamber-1793458283033';
const MASHRAFI = 'doctor_mMOqrPAdtIRH5a76t7Fx1ky8Bp83';
const NUZHAT = 'doctor_uHlqUgF07vZ8Ie4z54KinN9i0Li1';
const NUZHAT_DUP = 'doctor_nuzhat_saima';
const ADMIN_DOCTOR = 'doctor_LEPN8RB9Oeg5vXKX76plaXD57Zz2';
const KITTY_OLD = 'Dr. Hello Kitty';
const NAME = 'Bup Medical';

const FV = admin.firestore.FieldValue;
let db;
const removedChamberDoctors = new Set();
// Doctor ids that are merged into another; desk mappings and staff chats move.
const REMAP = { [NUZHAT_DUP]: NUZHAT };
const ops = [];
function plan(desc, fn) { ops.push({ desc, fn }); }

function dhakaDateKey() {
  const d = new Date(Date.now() + 6 * 3600 * 1000);
  return `${d.getUTCFullYear()}${String(d.getUTCMonth() + 1).padStart(2, '0')}${String(d.getUTCDate()).padStart(2, '0')}`;
}

async function chambers() {
  const canon = await db.collection('chambers').doc(CANONICAL).get();
  if (!canon.exists) throw new Error(`chambers/${CANONICAL} missing`);
  const c = canon.data();
  const entry = {
    id: CANONICAL, hospitalName: NAME, name: NAME,
    area: c.area || '', location: c.location || c.address || '',
    lat: c.lat ?? null, lng: c.lng ?? null,
  };
  plan(`rename chambers/${CANONICAL} "${c.name}" -> "${NAME}", doctors: Mashrafi + Nuzhat`, (b) =>
    b.update(canon.ref, {
      name: NAME, chamberName: NAME, hospitalName: NAME,
      doctorIds: FV.arrayUnion(MASHRAFI, NUZHAT),
      [`members.${MASHRAFI}`]: 'owner', [`members.${NUZHAT}`]: 'doctor',
      updatedAt: FV.serverTimestamp(),
    }));

  const all = await db.collection('chambers').get();
  for (const d of all.docs) {
    if (d.id === CANONICAL) continue;
    const x = d.data();
    const label = `${x.name || ''} ${x.hospitalName || ''} ${x.chamberName || ''}`.toLowerCase();
    const isBupMedical = label.includes('bup medical');
    const isBsl = /\bbsl\b/.test(label) || x.doctorId === ADMIN_DOCTOR || x.ownerDoctorId === ADMIN_DOCTOR;
    if (!isBupMedical && !isBsl) continue;
    [x.doctorId, x.ownerDoctorId, ...(x.doctorIds || [])].forEach((id) => id && removedChamberDoctors.add(id));
    plan(`remove chambers/${d.id} "${x.name || x.hospitalName}"${isBsl ? ' (admin BSL)' : ' (duplicate Bup Medical)'}`, (b) =>
      b.update(d.ref, { status: 'removed', hidden: true, isHidden: true, canonicalChamberId: CANONICAL, updatedAt: FV.serverTimestamp() }));
  }

  // Doctors' embedded chamber lists point at the one Bup Medical.
  for (const id of [MASHRAFI, NUZHAT]) {
    const snap = await db.collection('doctors').doc(id).get();
    if (!snap.exists) continue;
    const list = (snap.get('chambers') || []).filter((ch) => {
      const n = `${ch.hospitalName || ''} ${ch.name || ''} ${ch.id || ''}`.toLowerCase();
      return !(n.includes('bup') || ch.id === CANONICAL || /\bbsl\b/.test(n));
    });
    plan(`doctors/${id}: chambers -> [${NAME}${list.length ? ` + ${list.length} other` : ''}]`, (b) =>
      b.update(snap.ref, { chambers: [entry, ...list], updatedAt: FV.serverTimestamp() }));
  }
}

async function duplicates() {
  for (const id of removedChamberDoctors) {
    if ([MASHRAFI, NUZHAT, ADMIN_DOCTOR].includes(id)) continue;
    const d = await db.collection('doctors').doc(id).get();
    if (!d.exists || d.get('claimedByUid')) continue;
    plan(`hide unclaimed duplicate doctors/${d.id} "${d.get('name')}" (was on the old Bup Medical)`, (b) =>
      b.update(d.ref, { hidden: true, isHidden: true, mergedInto: MASHRAFI, updatedAt: FV.serverTimestamp() }));
  }
  const nDesks = await db.collection('chamber_operators').where('doctorId', '==', NUZHAT_DUP).get();
  nDesks.docs.forEach((d) => {
    const x = d.data();
    plan(`chamber_operators/${d.id} -> ${CANONICAL}_${NUZHAT}_${x.operatorUid}`, (b) => {
      b.set(db.collection('chamber_operators').doc(`${CANONICAL}_${NUZHAT}_${x.operatorUid}`),
        { ...x, chamberId: CANONICAL, chamberName: NAME, doctorId: NUZHAT, updatedAt: FV.serverTimestamp() });
      b.delete(d.ref);
    });
  });
  plan(`hide doctors/${NUZHAT_DUP} (duplicate of ${NUZHAT}), clear its claim`, (b) =>
    b.update(db.collection('doctors').doc(NUZHAT_DUP), {
      hidden: true, isHidden: true, mergedInto: NUZHAT,
      claimedByUid: FV.delete(), isClaimed: false, claimStatus: 'unclaimed',
      updatedAt: FV.serverTimestamp(),
    }));
  plan(`doctors/${ADMIN_DOCTOR}: drop BSL chamber, stay hidden`, (b) =>
    b.update(db.collection('doctors').doc(ADMIN_DOCTOR), { chambers: [], hidden: true, isHidden: true, updatedAt: FV.serverTimestamp() }));
  const desks = await db.collection('chamber_operators').where('doctorId', '==', ADMIN_DOCTOR).get();
  desks.docs.forEach((d) => plan(`delete desk mapping chamber_operators/${d.id} (admin BSL)`, (b) => b.delete(d.ref)));
}

async function salsabil() {
  const old = await db.collection('doctors').doc(KITTY_OLD).get();
  if (!old.exists) return;
  const data = old.data();
  const uid = data.claimedByUid;
  if (!uid) throw new Error('Dr. Hello Kitty has no owner; not moving');
  const newId = `doctor_${uid}`;
  REMAP[KITTY_OLD] = newId;
  const newRef = db.collection('doctors').doc(newId);
  plan(`doctors/"${KITTY_OLD}" -> doctors/${newId} "Dr. Salsabil"`, (b) =>
    b.set(newRef, { ...data, name: 'Dr. Salsabil', name_lower: 'dr. salsabil', updatedAt: FV.serverTimestamp() }));
  plan(`hide old doctors/"${KITTY_OLD}"`, (b) =>
    b.update(old.ref, { hidden: true, isHidden: true, mergedInto: newId, claimedByUid: FV.delete(), isClaimed: false, claimStatus: 'unclaimed' }));
  plan(`users/${uid}.doctorProfileId -> ${newId}`, (b) => b.update(db.collection('users').doc(uid), { doctorProfileId: newId }));

  for (const col of ['appointments', 'chats', 'reviews', 'queues', 'doctor_slots', 'chamber_day_overrides', 'active_bookings']) {
    const refs = await db.collection(col).where('doctorId', '==', KITTY_OLD).get();
    refs.docs.forEach((d) => plan(`${col}/${d.id}.doctorId -> ${newId}`, (b) => b.update(d.ref, { doctorId: newId })));
  }
  const ch = await db.collection('chambers').get();
  ch.docs.filter((d) => [d.get('doctorId'), d.get('ownerDoctorId')].includes(KITTY_OLD) || (d.get('doctorIds') || []).includes(KITTY_OLD))
    .forEach((d) => plan(`chambers/${d.id}: doctor refs -> ${newId}`, (b) => b.update(d.ref, {
      ...(d.get('doctorId') === KITTY_OLD ? { doctorId: newId } : {}),
      ...(d.get('ownerDoctorId') === KITTY_OLD ? { ownerDoctorId: newId } : {}),
      doctorIds: (d.get('doctorIds') || []).map((x) => (x === KITTY_OLD ? newId : x)),
    })));
  const desks = await db.collection('chamber_operators').where('doctorId', '==', KITTY_OLD).get();
  desks.docs.forEach((d) => {
    const x = d.data();
    plan(`chamber_operators/${d.id} -> ${x.chamberId}_${newId}_${x.operatorUid}`, (b) => {
      b.set(db.collection('chamber_operators').doc(`${x.chamberId}_${newId}_${x.operatorUid}`), { ...x, doctorId: newId, doctorName: 'Dr. Salsabil' });
      b.delete(d.ref);
    });
  });
}

async function chats() {
  const all = await db.collection('chats').get();
  all.docs.filter((d) => /^chat_.+_(operator_doctor|patient_operator)$/.test(d.id) && d.get('status') !== 'archived')
    .forEach((d) => plan(`archive per-appointment chat ${d.id}`, (b) => b.update(d.ref, { status: 'archived' })));

  // One staff chat per doctor that has a desk team.
  const desks = await db.collection('chamber_operators').get();
  const byDoctor = {};
  desks.docs.forEach((d) => {
    const x = d.data();
    if (x.doctorId === ADMIN_DOCTOR) return;
    const id = REMAP[x.doctorId] || x.doctorId;
    (byDoctor[id] ||= {})[x.operatorUid] = x.operatorName || 'Desk';
  });
  for (const [doctorId, operators] of Object.entries(byDoctor)) {
    // A remapped doctor's new doc may not exist yet: read the old one.
    const sourceId = Object.keys(REMAP).find((k) => REMAP[k] === doctorId && k !== NUZHAT_DUP) || doctorId;
    const doc = await db.collection('doctors').doc(sourceId).get();
    const doctorUid = doc.get('claimedByUid');
    if (!doctorUid) continue;
    const doctorName = sourceId === KITTY_OLD ? 'Dr. Salsabil' : doc.get('name');
    const uids = Object.keys(operators).filter((u) => u && u !== doctorUid);
    plan(`staff chat staff_${doctorId}: ${doctorName} + ${uids.length} operator(s)`, (b) =>
      b.set(db.collection('chats').doc(`staff_${doctorId}`), {
        type: 'staff',
        participants: [doctorUid, ...uids],
        participantRoles: { [doctorUid]: 'Doctor', ...Object.fromEntries(uids.map((u) => [u, 'Chamber desk'])) },
        participantNames: { [doctorUid]: doctorName, ...Object.fromEntries(uids.map((u) => [u, operators[u]])) },
        doctorUid, doctorId, doctorName,
        status: 'active', messageCount: FV.increment(0),
        lastMessage: 'Desk chat for appointments. New requests appear here.',
        updatedAt: FV.serverTimestamp(),
      }, { merge: true }));
  }
}

async function leftovers() {
  const users = await db.collection('users').get();
  users.docs.forEach((d) => {
    const literal = Object.keys(d.data()).filter((k) => k.startsWith('roles.'));
    if (!literal.length) return;
    // FieldPath targets the literal key; a dotted string would hit roles.*.
    plan(`users/${d.id}: delete literal ${literal.join(', ')}`, (b) =>
      b.update(d.ref, ...literal.flatMap((k) => [new admin.firestore.FieldPath(k), FV.delete()])));
  });
  const today = dhakaDateKey();
  const q = await db.collection('queues').get();
  q.docs.filter((d) => !d.get('doctorId') && String(d.get('date') || '').replace(/-/g, '') < today)
    .forEach((d) => plan(`delete old queue counter queues/${d.id}`, (b) => b.delete(d.ref)));
}

// Claimed doctors were all listed as General Medicine; give each a real
// speciality (same labels as the bundled directory).
const SPECIALITIES = {
  [`doctor_ddYOcogtrZadMJaotKuPTBWFOeG2`]: 'PEDIATRICIAN', // Dr. Salsabil
  [MASHRAFI]: 'CARDIOLOGIST',
  [NUZHAT]: 'DERMATOLOGIST',
  doctor_4CV4km0dvNhax1RoO65R4tbKgXz2: 'OTOLARYNGOLOGISTS (ENT)', // Dr. Faiza Neha
  doctor_z4DnDYM9TiciFN3W8t8R2Sq1IIj2: 'NEUROLOGIST', // Dr. ruhi
};

async function specialities() {
  for (const [id, spec] of Object.entries(SPECIALITIES)) {
    const d = await db.collection('doctors').doc(id).get();
    if (!d.exists) continue;
    plan(`doctors/${id} "${d.get('name')}": ${JSON.stringify(d.get('specialities'))} -> ["${spec}"]`, (b) =>
      b.update(d.ref, { specialities: [spec], designation: spec, updatedAt: FV.serverTimestamp() }));
  }
}

// Public chamber/doctor docs must not say who runs a desk (name, email, uid);
// that lives only in chamber_operators (which keeps no email either).
const OP_FIELDS = ['operatorUid', 'operatorName', 'operatorEmail'];
async function stripOperators() {
  const ch = await db.collection('chambers').get();
  ch.docs.filter((d) => OP_FIELDS.some((f) => d.get(f) !== undefined)).forEach((d) =>
    plan(`chambers/${d.id}: remove ${OP_FIELDS.filter((f) => d.get(f) !== undefined).join(', ')}`, (b) =>
      b.update(d.ref, Object.fromEntries(OP_FIELDS.map((f) => [f, FV.delete()])))));
  const claimed = await db.collection('doctors').where('claimedByUid', '>', '').get();
  const extra = await Promise.all([KITTY_OLD, NUZHAT_DUP, ADMIN_DOCTOR].map((id) => db.collection('doctors').doc(id).get()));
  for (const d of [...claimed.docs, ...extra.filter((x) => x.exists)]) {
    const list = d.get('chambers') || [];
    if (!list.some((c) => OP_FIELDS.some((f) => c[f] !== undefined))) continue;
    const clean = list.map((c) => Object.fromEntries(Object.entries(c).filter(([k]) => !OP_FIELDS.includes(k))));
    plan(`doctors/${d.id}: remove operator fields from ${list.length} chamber entr${list.length === 1 ? 'y' : 'ies'}`, (b) =>
      b.update(d.ref, { chambers: clean }));
  }
  const desks = await db.collection('chamber_operators').get();
  desks.docs.filter((d) => d.get('operatorEmail') !== undefined).forEach((d) =>
    plan(`chamber_operators/${d.id}: remove operatorEmail`, (b) => b.update(d.ref, { operatorEmail: FV.delete() })));
}

// The unclaimed test profile "Dr. Mashrafi" (Bup Medical) duplicates the real
// Dr. Mashrafi Elahi.
async function hideMashrafiDuplicate() {
  const snap = await db.collection('doctors').where('name', '==', 'Dr. Mashrafi').get();
  snap.docs.filter((d) => !d.get('claimedByUid') && !d.get('hidden')).forEach((d) =>
    plan(`hide duplicate doctors/${d.id} "${d.get('name')}"`, (b) =>
      b.update(d.ref, { hidden: true, isHidden: true, mergedInto: MASHRAFI, updatedAt: FV.serverTimestamp() })));
}

(async () => {
  initializeAdmin(admin);
  db = admin.firestore();
  if (process.argv.includes('--hide-mashrafi-dup')) {
    await hideMashrafiDuplicate();
    ops.forEach((o, i) => console.log(`${String(i + 1).padStart(2)}. ${o.desc}`));
    if (APPLY) for (const o of ops) { const b = db.batch(); o.fn(b); await b.commit(); }
    console.log(APPLY ? `\nApplied ${ops.length} changes.` : '\nDry run. Add --apply to write.');
    process.exit(0);
  }
  if (process.argv.includes('--strip-operators')) {
    await stripOperators();
    ops.forEach((o, i) => console.log(`${String(i + 1).padStart(2)}. ${o.desc}`));
    if (APPLY) for (const o of ops) { const b = db.batch(); o.fn(b); await b.commit(); }
    console.log(APPLY ? `\nApplied ${ops.length} changes.` : '\nDry run. Add --apply to write.');
    process.exit(0);
  }
  if (process.argv.includes('--specialities')) {
    // Only this step; the rest was applied on 2 Nov 2026.
    await specialities();
    ops.forEach((o, i) => console.log(`${String(i + 1).padStart(2)}. ${o.desc}`));
    if (APPLY) for (const o of ops) { const b = db.batch(); o.fn(b); await b.commit(); }
    console.log(APPLY ? `\nApplied ${ops.length} changes.` : '\nDry run. Add --apply to write.');
    process.exit(0);
  }
  await chambers();
  await duplicates();
  await salsabil();
  await chats();
  await leftovers();
  ops.forEach((o, i) => console.log(`${String(i + 1).padStart(2)}. ${o.desc}`));
  if (!APPLY) {
    console.log(`\nDry run: ${ops.length} changes. Re-run with --apply to write.`);
    process.exit(0);
  }
  for (const o of ops) {
    const b = db.batch();
    o.fn(b);
    await b.commit();
  }
  console.log(`\nApplied ${ops.length} changes.`);
  process.exit(0);
})().catch((e) => { console.error(e.message); process.exit(1); });
