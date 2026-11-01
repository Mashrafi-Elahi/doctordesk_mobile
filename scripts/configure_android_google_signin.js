require('dotenv').config();

const fs = require('fs');
const os = require('os');
const path = require('path');
const admin = require('firebase-admin');

const projectId = process.env.FIREBASE_PROJECT_ID || 'docdesk-1e4cc';
const androidAppId = '1:112062167979:android:d5dfb6f27a8ad7e6c270ee';
const certificates = [
  {
    certType: 'SHA_1',
    shaHash: 'A1:0F:C4:1C:03:52:15:F8:7D:C5:40:B1:84:CC:1D:63:2B:2F:A6:EE',
  },
  {
    certType: 'SHA_256',
    shaHash: '0E:88:FF:C9:62:E4:EE:04:DF:51:92:2B:71:5D:C3:4F:7F:81:45:45:EA:8E:B1:FF:04:E5:3E:D3:FF:0A:38:D7',
  },
];

function initializeAdmin() {
  if (admin.apps.length) return admin.credential.applicationDefault();

  const suppliedKey = process.env.GOOGLE_APPLICATION_CREDENTIALS;
  const localKey = ['serviceAccountKey.json', 'doctordesk-sa.json']
      .map((name) => path.join(__dirname, name))
      .find((candidate) => fs.existsSync(candidate));
  const keyPath = suppliedKey && fs.existsSync(suppliedKey) ? suppliedKey : localKey;
  let credential;

  if (keyPath) {
    credential = admin.credential.cert(keyPath);
  } else {
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

    const adcPath = path.join(os.tmpdir(), `doctordesk_google_${process.pid}.json`);
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
    credential = admin.credential.applicationDefault();
  }

  admin.initializeApp({ credential, projectId });
  return credential;
}

async function managementRequest(token, endpoint, method = 'GET', body) {
  const response = await fetch(`https://firebase.googleapis.com/v1beta1/${endpoint}`, {
    method,
    headers: {
      Authorization: `Bearer ${token}`,
      'Content-Type': 'application/json',
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  if (!response.ok) {
    throw new Error(`${method} ${endpoint} failed (${response.status}): ${await response.text()}`);
  }
  return response.status === 204 ? null : response.json();
}

async function main() {
  const credential = initializeAdmin();
  const { access_token: accessToken } = await credential.getAccessToken();
  const parent = `projects/${projectId}/androidApps/${androidAppId}`;
  const existing = await managementRequest(accessToken, `${parent}/sha`);
  const registered = new Set((existing.certificates || []).map(
      (item) => `${item.certType}:${item.shaHash}`));

  for (const certificate of certificates) {
    const key = `${certificate.certType}:${certificate.shaHash}`;
    if (registered.has(key)) {
      console.log(`${certificate.certType} is already registered.`);
      continue;
    }
    await managementRequest(accessToken, `${parent}/sha`, 'POST', {
      name: '',
      ...certificate,
    });
    console.log(`Registered Android ${certificate.certType}.`);
  }
}

main().catch((error) => {
  console.error('Android Google Sign-In setup failed:', error.message || error);
  process.exit(1);
});
