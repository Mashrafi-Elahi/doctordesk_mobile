require('dotenv').config();

const fs = require('fs');
const os = require('os');
const path = require('path');
const admin = require('firebase-admin');

const projectId = process.env.FIREBASE_PROJECT_ID || 'docdesk-1e4cc';
const ownerEmail = 'mashrafeelahi8@gmail.com';
const ownerName = 'DoctorDesk Admin';
const postId = 'doctordesk-welcome-video';

function initializeAdmin() {
  if (admin.apps.length) return admin.app();

  const suppliedKey = process.env.GOOGLE_APPLICATION_CREDENTIALS;
  const localKey = ['serviceAccountKey.json', 'doctordesk-sa.json']
      .map((name) => path.join(__dirname, name))
      .find((candidate) => fs.existsSync(candidate));
  const keyPath = suppliedKey && fs.existsSync(suppliedKey)
      ? suppliedKey
      : localKey;

  if (keyPath) {
    return admin.initializeApp({
      credential: admin.credential.cert(keyPath),
      projectId,
    });
  }

  const configPath = path.join(
      os.homedir(), '.config', 'configstore', 'firebase-tools.json');
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

async function main() {
  initializeAdmin();
  const authUser = await admin.auth().getUserByEmail(ownerEmail);
  const db = admin.firestore();
  const userRef = db.collection('users').doc(authUser.uid);
  const currentUser = await userRef.get();
  const existing = currentUser.data() || {};
  const existingRoles = existing.roles || {};

  const batch = db.batch();
  batch.set(userRef, {
    uid: authUser.uid,
    email: ownerEmail,
    name: existing.name || authUser.displayName || ownerName,
    roles: {
      ...existingRoles,
      isAdmin: true,
    },
    adminUpdatedAt: admin.firestore.FieldValue.serverTimestamp(),
  }, { merge: true });
  batch.set(db.collection('admins').doc(authUser.uid), {
    uid: authUser.uid,
    email: ownerEmail,
    name: ownerName,
    isAdmin: true,
    grantedAt: admin.firestore.FieldValue.serverTimestamp(),
  }, { merge: true });
  batch.set(db.collection('posts').doc(postId), {
    type: 'video',
    title: 'DoctorDesk: Welcome to Smarter Healthcare',
    content: 'Watch our introduction to DoctorDesk and discover how patients can find specialists and manage care in one place.',
    youtubeUrl: 'https://youtu.be/uFzgEeNLjYY',
    userId: authUser.uid,
    authorName: ownerName,
    authorRole: 'admin',
    isBmdcVerified: false,
    timestamp: admin.firestore.FieldValue.serverTimestamp(),
    answer: null,
    likesCount: 0,
    commentsCount: 0,
  }, { merge: true });
  await batch.commit();

  console.log(`Granted app admin role to ${ownerEmail} (${authUser.uid}).`);
  console.log(`Created/updated feed post ${postId}.`);
}

main().catch((error) => {
  console.error('Bootstrap failed:', error.message || error);
  process.exit(1);
});
