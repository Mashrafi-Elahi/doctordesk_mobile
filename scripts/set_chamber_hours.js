// Sets a chamber's regular visiting hours, and optionally today's override.
//
//   node scripts/set_chamber_hours.js <chamberId> --start 08:00 --end 20:00 [--days "Sat–Thu"] [--today] [--date YYYYMMDD] [--apply]
//
// Dry run by default: prints what it would change. --apply writes.
// --today also rewrites that day's chamber_day_overrides doc (today in Asia/Dhaka,
// or --date).

const fs = require('fs');
const os = require('os');
const path = require('path');
const admin = require('firebase-admin');

const projectId = process.env.FIREBASE_PROJECT_ID || 'docdesk-1e4cc';

function initializeAdmin() {
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
  const adcPath = path.join(os.tmpdir(), `doctordesk_hours_${process.pid}.json`);
  fs.writeFileSync(adcPath, JSON.stringify({
    type: 'authorized_user', client_id: clientId, client_secret: clientSecret, refresh_token: refreshToken,
  }));
  process.on('exit', () => { try { fs.unlinkSync(adcPath); } catch (_) {} });
  process.env.GOOGLE_APPLICATION_CREDENTIALS = adcPath;
  return admin.initializeApp({ credential: admin.credential.applicationDefault(), projectId });
}

function arg(name, fallback) {
  const i = process.argv.indexOf(name);
  return i > 0 ? process.argv[i + 1] : fallback;
}

function to12h(hhmm) {
  const [h, m] = hhmm.split(':').map(Number);
  const p = h >= 12 ? 'PM' : 'AM';
  return `${h % 12 === 0 ? 12 : h % 12}:${String(m).padStart(2, '0')} ${p}`;
}

function dhakaDateKey() {
  const d = new Date(Date.now() + 6 * 3600 * 1000);
  return `${d.getUTCFullYear()}${String(d.getUTCMonth() + 1).padStart(2, '0')}${String(d.getUTCDate()).padStart(2, '0')}`;
}

async function main() {
  const chamberId = process.argv[2];
  if (!chamberId || chamberId.startsWith('--')) throw new Error('Usage: set_chamber_hours.js <chamberId> --start HH:MM --end HH:MM');
  const start = arg('--start', '08:00');
  const end = arg('--end', '20:00');
  const days = arg('--days', null);
  const apply = process.argv.includes('--apply');
  const today = process.argv.includes('--today');

  initializeAdmin();
  const db = admin.firestore();
  const ref = db.collection('chambers').doc(chamberId);
  const snap = await ref.get();
  if (!snap.exists) throw new Error(`chambers/${chamberId} not found`);
  const d = snap.data();
  const current = typeof d.visitingHours === 'string' ? d.visitingHours
    : (d.visitingHours && d.visitingHours.display) || d.visitingHoursDisplay || '';
  const dayPart = days || (current.match(/\(([^)]*)\)/) || [])[1] || 'Sat–Thu';
  const display = `${to12h(start)} – ${to12h(end)} (${dayPart})`;

  console.log(`chamber: ${chamberId} (${d.name || d.chamberName || ''})`);
  console.log(`  visitingHours now : ${JSON.stringify(d.visitingHours ?? d.visitingHoursDisplay ?? null)}`);
  console.log(`  visitingHours new : "${display}"`);

  const [sh, sm] = start.split(':').map(Number);
  const [eh, em] = end.split(':').map(Number);
  const overrideId = `${chamberId}_${arg('--date', dhakaDateKey())}`;
  const overrideRef = db.collection('chamber_day_overrides').doc(overrideId);
  const ov = await overrideRef.get();
  console.log(`  day override ${overrideId}: ${ov.exists ? JSON.stringify(ov.data(), (k, v) => (k === 'updatedAt' ? undefined : v)) : 'none'}`);
  if (today) console.log(`  today override new : ${start}–${end}`);

  if (!apply) {
    console.log('\nDry run. Re-run with --apply to write.');
    return;
  }
  const hoursUpdate = typeof d.visitingHours === 'object' && d.visitingHours !== null
    ? {
        'visitingHours.display': display,
        'visitingHours.start': start,
        'visitingHours.end': end,
        visitingHoursDisplay: display,
      }
    : { visitingHours: display, visitingHoursDisplay: display };
  await ref.update({ ...hoursUpdate, updatedAt: admin.firestore.FieldValue.serverTimestamp() });
  if (today && ov.exists) {
    await overrideRef.update({
      startHour: sh, startMinute: sm, endHour: eh, endMinute: em,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
  }
  console.log('\nApplied.');
}

main().then(() => process.exit(0)).catch((e) => { console.error(e.message); process.exit(1); });
