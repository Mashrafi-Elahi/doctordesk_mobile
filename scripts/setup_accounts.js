const admin = require('firebase-admin');
const path = require('path');
const sa = require('../tools/serviceAccount.json');

if (!admin.apps.length) {
  admin.initializeApp({
    credential: admin.credential.cert(sa),
    projectId: 'docdesk-1e4cc',
  });
}
const db = admin.firestore();

const isApply = process.argv.includes('--apply');
const isDryRun = !isApply || process.argv.includes('--dry-run');

async function setupAccounts() {
  console.log(`====================================================`);
  console.log(`ACCOUNT SETUP & OPERATOR MAPPING`);
  console.log(`Mode: ${isDryRun ? 'DRY RUN (Read-only, NO changes will be written)' : 'APPLY (Writing changes to Firestore)'}`);
  console.log(`====================================================\n`);

  const emailsToFind = [
    { email: 'mashrafielahi@gmail.com', role: 'Doctor (Owner)', chamber: 'Bup' },
    { email: 'nuzhatsaima.16@gmail.com', role: 'Doctor (Visiting)', chamber: 'Bup' },
    { email: 'mahi17088@gmail.com', fallback: 'mahil7088@gmail.com', role: 'Operator for Dr. Mashrafi Elahi', chamber: 'Bup' },
    { email: 'rehnumasalsabil@gmail.com', role: 'Operator for Dr. Nuzhat Saima', chamber: 'Bup' },
    { email: 'mashrafeelahi8@gmail.com', role: 'Admin only (Soft-hide doctor profile & BSL chamber)' },
  ];

  const resolvedUsers = {};

  for (const item of emailsToFind) {
    let authUser = null;
    let usedEmail = item.email;
    try {
      authUser = await admin.auth().getUserByEmail(usedEmail);
    } catch (e) {
      if (item.fallback) {
        try {
          authUser = await admin.auth().getUserByEmail(item.fallback);
          usedEmail = item.fallback;
        } catch (_) {}
      }
    }

    if (!authUser) {
      console.log(`[ALERT] Email NOT FOUND in Firebase Auth: ${item.email} ${item.fallback ? `(also checked ${item.fallback})` : ''}`);
      continue;
    }

    const uSnap = await db.collection('users').doc(authUser.uid).get();
    resolvedUsers[item.email] = {
      email: usedEmail,
      uid: authUser.uid,
      displayName: authUser.displayName,
      userDocExists: uSnap.exists,
      userData: uSnap.exists ? uSnap.data() : null,
      targetRole: item.role,
    };
    console.log(`[FOUND] ${usedEmail} -> UID: ${authUser.uid} (${item.role})`);
  }

  const plannedUpdates = [];

  // 1. Dr. Mashrafi Elahi (Owner of Bup)
  const mashrafiUser = resolvedUsers['mashrafielahi@gmail.com'];
  if (mashrafiUser) {
    plannedUpdates.push({
      target: `users/${mashrafiUser.uid}`,
      data: {
        'roles.isDoctor': true,
        'roles.isOperator': false,
        doctorProfileId: 'doctor_mMOqrPAdtIRH5a76t7Fx1ky8Bp83',
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      reason: 'Ensure doctor role and doctorProfileId for Dr. Mashrafi Elahi',
    });

    plannedUpdates.push({
      target: `doctors/doctor_mMOqrPAdtIRH5a76t7Fx1ky8Bp83`,
      data: {
        claimedByUid: mashrafiUser.uid,
        isBmdcVerified: true,
        verificationStatus: 'verified',
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      reason: 'Verify and claim doctor profile for Dr. Mashrafi Elahi',
    });
  }

  // 2. Dr. Nuzhat Saima (Visiting doctor of Bup)
  const nuzhatUser = resolvedUsers['nuzhatsaima.16@gmail.com'];
  if (nuzhatUser) {
    plannedUpdates.push({
      target: `users/${nuzhatUser.uid}`,
      data: {
        'roles.isDoctor': true,
        'roles.isOperator': false,
        doctorProfileId: 'doctor_nuzhat_saima', // Keep her existing doctor profile!
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      reason: 'Ensure doctor role and keep existing doctorProfileId for Dr. Nuzhat Saima',
    });

    // Keep her existing doctor profile doctor_nuzhat_saima, add canonical chamber Bup
    const nuzhatDocSnap = await db.collection('doctors').doc('doctor_nuzhat_saima').get();
    const existingChambers = nuzhatDocSnap.exists ? (nuzhatDocSnap.data()?.chambers || []) : [];
    const bupChamberEntry = {
      id: 'chamber-1793458283033',
      name: 'Bup',
      hospitalName: 'Bup',
      area: 'Mirpur Cantonment',
      location: 'Dhaka',
      visitingHours: '5:00 PM – 9:00 PM (Sat–Thu)',
      slotMinutes: 10,
      fee: 800,
      isAccessible: true,
      hasOperator: true,
      operatorUid: 'b1hA1IJVoTZRK71wnMD4cOustFn1',
      operatorEmail: 'rehnumasalsabil@gmail.com',
      role: 'visiting',
    };
    const updatedChambers = [
      ...existingChambers.filter(c => c.id !== 'chamber-1793458283033' && c.hospitalName !== 'Bup'),
      bupChamberEntry,
    ];

    plannedUpdates.push({
      target: `doctors/doctor_nuzhat_saima`,
      data: {
        claimedByUid: nuzhatUser.uid,
        isBmdcVerified: true,
        verificationStatus: 'verified',
        chambers: updatedChambers,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      reason: 'Update Dr. Nuzhat Saima profile with Bup chamber as visiting doctor',
    });
  }

  // 3. Desk Operators
  // (a) Mahi Khan for Dr. Mashrafi Elahi at chamber Bup
  const mahiUser = resolvedUsers['mahi17088@gmail.com'];
  if (mahiUser) {
    const chamberId = 'chamber-1793458283033';
    const doctorId = 'doctor_mMOqrPAdtIRH5a76t7Fx1ky8Bp83';
    const mappingId = `${chamberId}_${doctorId}_${mahiUser.uid}`;

    plannedUpdates.push({
      target: `chamber_operators/${mappingId}`,
      data: {
        chamberId,
        doctorId,
        doctorName: 'Dr. Mashrafi Elahi',
        chamberName: 'Bup',
        operatorUid: mahiUser.uid,
        operatorEmail: mahiUser.email,
        operatorName: mahiUser.displayName || 'Mahi Khan',
        assignedByDoctorUid: mashrafiUser ? mashrafiUser.uid : null,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      reason: 'Chamber operator mapping for Dr. Mashrafi Elahi at Bup',
    });

    plannedUpdates.push({
      target: `users/${mahiUser.uid}`,
      data: {
        'roles.isOperator': true,
        operatorAssignments: [chamberId],
        assignedChambers: [
          {
            chamberId,
            chamberName: 'Bup',
            doctorId,
            doctorName: 'Dr. Mashrafi Elahi',
          }
        ],
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      reason: 'Update user roles and assignments for operator Mahi',
    });
  }

  // (b) Rehnuma for Dr. Nuzhat Saima at chamber Bup
  const rehnumaUser = resolvedUsers['rehnumasalsabil@gmail.com'];
  if (rehnumaUser) {
    const chamberId = 'chamber-1793458283033';
    const doctorId = 'doctor_nuzhat_saima';
    const mappingId = `${chamberId}_${doctorId}_${rehnumaUser.uid}`;

    plannedUpdates.push({
      target: `chamber_operators/${mappingId}`,
      data: {
        chamberId,
        doctorId,
        doctorName: 'Dr. Nuzhat Saima',
        chamberName: 'Bup',
        operatorUid: rehnumaUser.uid,
        operatorEmail: rehnumaUser.email,
        operatorName: rehnumaUser.displayName || 'Rehnuma',
        assignedByDoctorUid: nuzhatUser ? nuzhatUser.uid : null,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      reason: 'Chamber operator mapping for Dr. Nuzhat Saima at Bup',
    });

    plannedUpdates.push({
      target: `users/${rehnumaUser.uid}`,
      data: {
        'roles.isOperator': true,
        operatorAssignments: [chamberId],
        assignedChambers: [
          {
            chamberId,
            chamberName: 'Bup',
            doctorId,
            doctorName: 'Dr. Nuzhat Saima',
          }
        ],
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      reason: 'Update user roles and assignments for operator Rehnuma',
    });
  }

  // 4. mashrafeelahi8@gmail.com stays Admin only
  const adminUser = resolvedUsers['mashrafeelahi8@gmail.com'];
  if (adminUser) {
    // Soft-hide its doctor profile from discovery
    plannedUpdates.push({
      target: `doctors/doctor_${adminUser.uid}`,
      data: {
        hidden: true,
        isHidden: true,
        hiddenReason: 'Admin account, not clinical practitioner',
        hiddenBy: 'system',
        hiddenAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      reason: 'Soft-hide admin doctor profile from discovery (no hard delete)',
    });

    // Hide chamber BSL linked to it (chamber-1793457537320)
    plannedUpdates.push({
      target: `chambers/chamber-1793457537320`,
      data: {
        hidden: true,
        isHidden: true,
        hiddenReason: 'Linked to admin profile',
        hiddenBy: 'system',
        hiddenAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      reason: 'Hide chamber BSL linked to admin profile',
    });

    // Ensure admins collection has this user
    plannedUpdates.push({
      target: `admins/${adminUser.uid}`,
      data: {
        uid: adminUser.uid,
        email: adminUser.email,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      reason: 'Ensure admin entry is preserved in admins collection',
    });

    // Ensure users doc has roles.isAdmin = true, roles.isDoctor = false
    plannedUpdates.push({
      target: `users/${adminUser.uid}`,
      data: {
        'roles.isAdmin': true,
        'roles.isDoctor': false,
        'roles.isOperator': false,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      reason: 'Admin-only roles on user doc',
    });
  }

  // 5. Re-route pending appointments for Dr. Mashrafi Elahi to handledBy: 'operator'
  const pendingAppts = await db.collection('appointments')
    .where('doctorId', '==', 'doctor_mMOqrPAdtIRH5a76t7Fx1ky8Bp83')
    .where('status', '==', 'requested')
    .get();

  pendingAppts.forEach(docSnap => {
    plannedUpdates.push({
      target: `appointments/${docSnap.id}`,
      data: {
        handledBy: 'operator',
        operatorUid: mahiUser ? mahiUser.uid : null,
        chamberId: 'chamber-1793458283033',
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      reason: `Reroute pending request ${docSnap.id} to assigned operator`,
    });
  });

  console.log(`\n================== ACCOUNT SETUP PLAN SUMMARY ==================`);
  console.log(`Total Planned Document Updates: ${plannedUpdates.length}\n`);
  plannedUpdates.forEach((item, index) => {
    console.log(`${index + 1}. Target: ${item.target}`);
    console.log(`   Reason: ${item.reason}`);
    console.log(`   Data: ${JSON.stringify(item.data, null, 2)}\n`);
  });

  if (isDryRun) {
    console.log(`[DRY RUN COMPLETE] No documents were written or modified. Use --apply to execute after confirmation.`);
    return;
  }

  console.log(`Applying updates to Firestore...`);
  const batch = db.batch();
  for (const item of plannedUpdates) {
    const [col, docId] = item.target.split('/');
    const ref = db.collection(col).doc(docId);
    // set() stores 'roles.isDoctor' as a literal top-level key; nest dotted
    // keys so merge updates the roles map instead.
    batch.set(ref, nestDottedKeys(item.data), { merge: true });
  }
  await batch.commit();
  console.log(`[SUCCESS] Account setup applied successfully!`);
}

setupAccounts().catch(console.error).finally(() => process.exit(0));

function nestDottedKeys(data) {
  const out = {};
  for (const [key, value] of Object.entries(data)) {
    const parts = key.split('.');
    let node = out;
    for (const part of parts.slice(0, -1)) node = node[part] = node[part] || {};
    node[parts[parts.length - 1]] = value;
  }
  return out;
}
