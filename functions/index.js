// DoctorDesk queue watcher. Runs every minute (needs the Blaze plan to deploy):
//  - flags consultations that ran past autoAdvanceAt (never ends them), and
//  - tells the lowest waiting token in each active queue "you're next", once.
// The app does both on its own too; this covers desks that are not open.

const { onSchedule } = require('firebase-functions/v2/scheduler');
const { initializeApp } = require('firebase-admin/app');
const { getFirestore, FieldValue, Timestamp } = require('firebase-admin/firestore');

initializeApp();
const db = getFirestore();

function todayKey(now) {
  // Bangladesh time (UTC+6), matching the app's local date keys.
  const d = new Date(now.getTime() + 6 * 60 * 60 * 1000);
  return `${d.getUTCFullYear()}${String(d.getUTCMonth() + 1).padStart(2, '0')}${String(d.getUTCDate()).padStart(2, '0')}`;
}

async function flagOverruns(now) {
  const snap = await db.collection('appointments')
    .where('status', '==', 'in_consultation')
    .where('autoAdvanceAt', '<=', Timestamp.fromDate(now))
    .get();
  const batch = db.batch();
  let n = 0;
  for (const doc of snap.docs) {
    if (doc.get('overrunFlaggedAt')) continue;
    batch.update(doc.ref, { overrun: true, overrunFlaggedAt: FieldValue.serverTimestamp() });
    n++;
  }
  if (n) await batch.commit();
  return n;
}

async function notifyNext(now) {
  const queues = await db.collection('queues')
    .where('date', '==', todayKey(now))
    .where('waitingCount', '>', 0)
    .get();
  let sent = 0;
  for (const q of queues.docs) {
    const next = await db.collection('appointments')
      .where('chamberId', '==', q.get('chamberId'))
      .where('doctorId', '==', q.get('doctorId'))
      .where('queueId', '==', q.id)
      .where('status', 'in', ['confirmed', 'checked_in'])
      .orderBy('queuePosition')
      .limit(1)
      .get();
    if (next.empty) continue;
    const appt = next.docs[0];
    const uid = appt.get('userId');
    if (!uid || appt.get('nextNotifiedAt')) continue;
    const created = await db.runTransaction(async (tx) => {
      const fresh = await tx.get(appt.ref);
      if (fresh.get('nextNotifiedAt')) return false;
      tx.update(appt.ref, { nextNotifiedAt: FieldValue.serverTimestamp() });
      tx.create(db.collection('notifications').doc(), {
        // Same shape as NotificationService.createNotification in the app.
        userId: uid,
        recipientId: uid,
        title: "You're next",
        body: `Token #${appt.get('queuePosition')} — please be ready at ${appt.get('chamberName') || 'the chamber'}.`,
        type: 'queue_next',
        relatedId: appt.id,
        isRead: false,
        timestamp: FieldValue.serverTimestamp(),
        expiresAt: Timestamp.fromMillis(Date.now() + 30 * 24 * 60 * 60 * 1000),
      });
      return true;
    });
    if (created) sent++;
  }
  return sent;
}

exports.queueWatcher = onSchedule(
  { schedule: 'every 1 minutes', region: 'asia-south2', timeZone: 'Asia/Dhaka' },
  async () => {
    const now = new Date();
    const flagged = await flagOverruns(now);
    const notified = await notifyNext(now);
    console.log(`queueWatcher: flagged=${flagged} notified=${notified}`);
  },
);
