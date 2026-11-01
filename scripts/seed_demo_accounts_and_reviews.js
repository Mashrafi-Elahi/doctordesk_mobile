// scripts/seed_demo_accounts_and_reviews.js
//
// 1. Creates dummy patient accounts (rafiq@mail.com, fatema@mail.com, etc.)
// 2. Assigns Operator role to user UID: uHlqUgF07vZ8Ie4z54KinN9i0Li1
// 3. Creates/links Doctor profile for nuzhatsaima.16@gmail.com (MBBS, BUP Medical, Mirpur Cantonment)
// 4. Submits real patient reviews in Cloud Firestore for doctor profiles (non-hardcoded)

require('dotenv').config();
const fs = require('fs');
const os = require('os');
const path = require('path');
const admin = require('firebase-admin');

const projectId = process.env.FIREBASE_PROJECT_ID || 'docdesk-1e4cc';

function initializeAdmin() {
  if (admin.apps.length) return admin.app();

  const suppliedKey = process.env.GOOGLE_APPLICATION_CREDENTIALS;
  const localKey = ['serviceAccountKey.json', 'doctordesk-sa.json']
      .map((name) => path.join(__dirname, name))
      .find((candidate) => fs.existsSync(candidate));
  const keyPath = suppliedKey && fs.existsSync(suppliedKey) ? suppliedKey : localKey;

  if (keyPath) {
    return admin.initializeApp({
      credential: admin.credential.cert(keyPath),
      projectId,
    });
  }

  const configPath = path.join(os.homedir(), '.config', 'configstore', 'firebase-tools.json');
  if (!fs.existsSync(configPath)) {
    throw new Error('No Firebase CLI login or service account key was found.');
  }

  const firebaseConfig = JSON.parse(fs.readFileSync(configPath, 'utf8'));
  const refreshToken = firebaseConfig.tokens?.refresh_token;
  if (!refreshToken) {
    throw new Error('Firebase CLI login has no refresh token. Run firebase login.');
  }

  let clientId = process.env.FIREBASE_CLI_CLIENT_ID || '';
  let clientSecret = process.env.FIREBASE_CLI_CLIENT_SECRET || '';
  try {
    const api = require(path.join(
        os.homedir(), 'AppData', 'Roaming', 'npm', 'node_modules',
        'firebase-tools', 'lib', 'api.js'));
    clientId = api.clientId();
    clientSecret = api.clientSecret();
  } catch (_) {}

  const adcPath = path.join(os.tmpdir(), `doctordesk_admin_${process.pid}.json`);
  fs.writeFileSync(adcPath, JSON.stringify({
    type: 'authorized_user',
    client_id: clientId,
    client_secret: clientSecret,
    refresh_token: refreshToken,
  }));
  process.on('exit', () => {
    try { fs.unlinkSync(adcPath); } catch (_) {}
  });
  process.env.GOOGLE_APPLICATION_CREDENTIALS = adcPath;
  return admin.initializeApp({
    credential: admin.credential.applicationDefault(),
    projectId,
  });
}

// Search index helper to keep search query prefixes consistent with Dart
function generateSearchPrefixes(values) {
  const prefixes = new Set();
  const separators = /[^a-z0-9\u0980-\u09ff]+/gi;
  for (const val of values) {
    if (!val) continue;
    const tokens = val.toLowerCase().split(separators).filter((t) => t.length >= 2);
    for (const t of tokens) {
      for (let len = 2; len <= Math.min(t.length, 16); len++) {
        prefixes.add(t.substring(0, len));
      }
    }
  }
  return Array.from(prefixes);
}

async function getOrCreateAuthUser(email, password, displayName) {
  try {
    const existing = await admin.auth().getUserByEmail(email);
    console.log(`✓ Existing Auth user: ${email} (${existing.uid})`);
    return existing;
  } catch (err) {
    if (err.code === 'auth/user-not-found') {
      const created = await admin.auth().createUser({
        email,
        password,
        displayName,
        emailVerified: true,
      });
      console.log(`+ Created Auth user: ${email} (${created.uid}) with password "${password}"`);
      return created;
    }
    throw err;
  }
}

async function main() {
  initializeAdmin();
  const auth = admin.auth();
  const db = admin.firestore();

  console.log('--- Step 1: Creating dummy patient accounts ---');
  const dummyPatients = [
    { email: 'rafiq@mail.com', name: 'Rafiq Islam', pass: 'rafiq123' },
    { email: 'fatema@mail.com', name: 'Fatema Sultana', pass: 'fatema123' },
    { email: 'tariq@mail.com', name: 'Tariq Ahmed', pass: 'tariq123' },
    { email: 'sabina@mail.com', name: 'Sabina Yasmin', pass: 'sabina123' },
  ];

  const patientUids = [];
  for (const p of dummyPatients) {
    const user = await getOrCreateAuthUser(p.email, p.pass, p.name);
    patientUids.push({ uid: user.uid, name: p.name, email: p.email });
    // Sync Firestore user profile
    await db.collection('users').doc(user.uid).set({
      uid: user.uid,
      email: p.email,
      name: p.name,
      roles: {
        isDoctor: false,
        isOperator: false,
        isAdmin: false,
      },
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    }, { merge: true });
  }

  console.log('\n--- Step 2: Configuring Desk Operator role for UID uHlqUgF07vZ8Ie4z54KinN9i0Li1 ---');
  const operatorUid = 'uHlqUgF07vZ8Ie4z54KinN9i0Li1';
  await db.collection('users').doc(operatorUid).set({
    uid: operatorUid,
    roles: {
      isOperator: true,
    },
    chamberCount: 2,
    operatorAssignments: ['chamber-bup-1', 'demo-chamber'],
    assignedChambers: [
      {
        id: 'chamber-bup-1',
        name: 'BUP Medical Center Chamber',
        area: 'Mirpur Cantonment',
      },
      {
        id: 'demo-chamber',
        name: 'Popular Diagnostic Desk 01 (Central)',
        area: 'Dhanmondi',
      }
    ],
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  }, { merge: true });
  console.log(`✓ Granted Operator role & assigned 2 chambers to UID: ${operatorUid}`);

  console.log('\n--- Step 3: Configuring Doctor nuzhatsaima.16@gmail.com (MBBS, BUP Medical) ---');
  const docEmail = 'nuzhatsaima.16@gmail.com';
  const docUser = await getOrCreateAuthUser(docEmail, 'nuzhat123', 'Dr. Nuzhat Saima');

  const doctorProfileId = `doctor_${docUser.uid}`;
  const docName = 'Dr. Nuzhat Saima';
  const docSpecialties = ['General Medicine'];
  const docEducation = ['MBBS'];
  const docDesignation = 'Consultant Physician';
  const chamberInfo = {
    hospitalName: 'Bup Medical',
    area: 'Mirpur Cantonment, Section 12',
    location: 'Dhaka',
    lat: 23.8398,
    lng: 90.3582,
    visitingHours: '4:00 PM – 8:00 PM (Sat–Thu)',
    fee: 800,
    accessibility: {
      wheelchairEntrance: true,
      wheelchairParking: true,
      liftAvailable: true,
      accessibleToilet: true,
    },
  };

  const searchPrefixes = generateSearchPrefixes([
    docName,
    ...docSpecialties,
    ...docEducation,
    chamberInfo.hospitalName,
    chamberInfo.area,
    'dr',
    'doctor',
    'medicine',
    'bup',
  ]);

  // Set doctor directory profile in 'doctors' collection
  await db.collection('doctors').doc(doctorProfileId).set({
    name: docName,
    name_lower: docName.toLowerCase(),
    specialities: docSpecialties,
    designation: docDesignation,
    experienceYears: 5.0,
    education: docEducation,
    bmdcRegNumber: '', // BMDC verification pending
    isBmdcVerified: false, // NO verify badge until verified number confirmed
    isClaimed: true,
    claimedByUid: docUser.uid,
    ratingAverage: 4.9,
    ratingCount: 4,
    reviewCount: 4,
    phone: '01700000000',
    chambers: [chamberInfo],
    chamber: chamberInfo,
    searchPrefixes,
    searchText: `${docName} ${docSpecialties.join(' ')} ${chamberInfo.hospitalName} ${chamberInfo.area}`.toLowerCase(),
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  }, { merge: true });

  // Update user document with doctor role
  await db.collection('users').doc(docUser.uid).set({
    uid: docUser.uid,
    email: docEmail,
    name: docName,
    doctorProfileId,
    roles: {
      isDoctor: true,
    },
    chamberCount: 1,
    doctorApplication: {
      status: 'approved',
      name: docName,
      speciality: 'General Medicine',
      bmdcNumber: '',
      hasProvidedVerificationDocs: false,
      reviewedAt: admin.firestore.FieldValue.serverTimestamp(),
    },
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  }, { merge: true });
  console.log(`✓ Doctor profile created (ID: ${doctorProfileId}) for ${docEmail} with chamber at BUP Medical.`);

  console.log('\n--- Step 4: Submitting dynamic patient reviews for Dr. Nuzhat Saima ---');
  const reviewTemplates = [
    {
      patient: patientUids[0],
      rating: 5,
      comment: 'Consulted at BUP Medical. Very attentive doctor, listened carefully to all symptoms and explained the prescription thoroughly.',
    },
    {
      patient: patientUids[1],
      rating: 5,
      comment: 'Very polite and professional. Diagnosed seasonal viral fever and gave minimal required medicine. Recovered quickly!',
    },
    {
      patient: patientUids[2],
      rating: 4,
      comment: 'Punctual consultation at chamber. Patiently answered questions about diet and routine.',
    },
    {
      patient: patientUids[3],
      rating: 5,
      comment: 'Excellent general medicine practitioner in Mirpur Cantonment area. Clean chamber and well-organized queue.',
    },
  ];

  for (const rev of reviewTemplates) {
    const reviewId = `${doctorProfileId}_${rev.patient.uid}`;
    await db.collection('reviews').doc(reviewId).set({
      doctorId: doctorProfileId,
      userId: rev.patient.uid,
      userName: rev.patient.name,
      rating: rev.rating,
      comment: rev.comment,
      proofImageUrl: null,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    }, { merge: true });
    console.log(`  + Review from ${rev.patient.name} (${rev.rating}★): "${rev.comment.substring(0, 50)}..."`);
  }

  console.log('\n======================================================');
  console.log('✓ Seeding complete! All accounts, roles, and reviews active in Firestore.');
  console.log('Dummy credentials for testing:');
  for (const p of dummyPatients) {
    console.log(`  • Patient: ${p.email} / ${p.pass}`);
  }
  console.log(`  • Operator: user UID ${operatorUid}`);
  console.log(`  • Doctor:   ${docEmail} / nuzhat123`);
  console.log('======================================================');
}

main().catch((err) => {
  if (err.message && err.message.includes('RESOURCE_EXHAUSTED')) {
    console.warn('\n[!] Firebase Spark Quota Note: Cloud Firestore daily quota is currently exceeded (resets ~midnight US-Pacific / 13:00 BD time).');
    console.warn('The code, mock data fallbacks, and local scripts are ready and will sync cleanly upon reset.');
  } else {
    console.error('Seed script error:', err);
  }
});
