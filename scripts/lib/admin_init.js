// Shared firebase-admin setup for scripts. Uses GOOGLE_APPLICATION_CREDENTIALS
// when set, otherwise the logged-in Firebase CLI account.

const fs = require('fs');
const os = require('os');
const path = require('path');

const projectId = process.env.FIREBASE_PROJECT_ID || 'docdesk-1e4cc';

function initializeAdmin(admin) {
  if (admin.apps.length) return admin.app();
  const keyPath = process.env.GOOGLE_APPLICATION_CREDENTIALS;
  if (keyPath && fs.existsSync(keyPath)) {
    return admin.initializeApp({ credential: admin.credential.cert(keyPath), projectId });
  }
  const configPath = path.join(os.homedir(), '.config', 'configstore', 'firebase-tools.json');
  const refreshToken = JSON.parse(fs.readFileSync(configPath, 'utf8')).tokens?.refresh_token;
  if (!refreshToken) throw new Error('Run firebase login first.');
  let clientId = process.env.FIREBASE_CLI_CLIENT_ID || '';
  let clientSecret = process.env.FIREBASE_CLI_CLIENT_SECRET || '';
  try {
    const api = require(path.join(os.homedir(), 'AppData', 'Roaming', 'npm', 'node_modules',
        'firebase-tools', 'lib', 'api.js'));
    clientId = api.clientId();
    clientSecret = api.clientSecret();
  } catch (_) {}
  const adcPath = path.join(os.tmpdir(), `doctordesk_admin_${process.pid}.json`);
  fs.writeFileSync(adcPath, JSON.stringify({
    type: 'authorized_user', client_id: clientId, client_secret: clientSecret, refresh_token: refreshToken,
  }));
  process.on('exit', () => { try { fs.unlinkSync(adcPath); } catch (_) {} });
  process.env.GOOGLE_APPLICATION_CREDENTIALS = adcPath;
  return admin.initializeApp({ credential: admin.credential.applicationDefault(), projectId });
}

module.exports = { initializeAdmin, projectId };
