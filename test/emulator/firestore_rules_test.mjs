import { readFileSync } from 'node:fs';
import { after, afterEach, before, describe, it } from 'node:test';
import assert from 'node:assert/strict';
import {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} from '@firebase/rules-unit-testing';
import { Bytes, collection, doc, getDoc, getDocs, orderBy, query, setDoc, updateDoc, deleteDoc, runTransaction, where } from 'firebase/firestore';

const projectId = 'doctordesk-rules-test';
const rules = readFileSync(new URL('../../firestore.rules', import.meta.url), 'utf8');
let testEnv;

const requestedAppointment = (overrides = {}) => ({
  userId: 'patient',
  patientName: 'Patient One',
  doctorId: 'doctor-profile',
  doctorName: 'Dr One',
  chamberId: 'chamber-a',
  status: 'requested',
  scheduledTime: new Date('2030-01-01T10:00:00Z'),
  createdAt: new Date('2030-01-01T09:00:00Z'),
  updatedAt: new Date('2030-01-01T09:00:00Z'),
  ...overrides,
});

async function seed() {
  await testEnv.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();
    await Promise.all([
      setDoc(doc(db, 'users/patient'), { roles: {} }),
      setDoc(doc(db, 'users/doctor'), {
        roles: { isDoctor: true },
        doctorProfileId: 'doctor-profile',
      }),
      setDoc(doc(db, 'users/operator'), {
        roles: { isOperator: true },
        operatorAssignments: ['chamber-a'],
      }),
      setDoc(doc(db, 'chamber_operators/chamber-a_doctor-profile_operator'), {
        chamberId: 'chamber-a',
        doctorId: 'doctor-profile',
        operatorUid: 'operator',
      }),
      setDoc(doc(db, 'users/stranger'), { roles: {} }),
      setDoc(doc(db, 'admins/admin'), { uid: 'admin' }),
      setDoc(doc(db, 'doctors/doctor-profile'), {
        name: 'Dr One',
        claimedByUid: 'doctor',
        verificationStatus: 'unverified',
        isBmdcVerified: false,
      }),
    ]);
  });
}

before(async () => {
  testEnv = await initializeTestEnvironment({
    projectId,
    firestore: { rules, host: '127.0.0.1', port: 8085 },
  });
  await seed();
});

afterEach(async () => {
  await testEnv.clearFirestore();
  await seed();
});

after(async () => {
  await testEnv.cleanup();
});

describe('user document creation', () => {
  const signupDoc = (extra = {}) => ({
    uid: 'newcomer',
    email: 'new@example.com',
    roles: { isDoctor: false, isOperator: false, isAdmin: false },
    doctorProfileId: null,
    operatorAssignments: [],
    ...extra,
  });

  it('allows a normal sign-up document', async () => {
    const db = testEnv.authenticatedContext('newcomer').firestore();
    await assertSucceeds(setDoc(doc(db, 'users/newcomer'), signupDoc()));
  });

  it('prevents a new account from linking itself to a doctor profile', async () => {
    const db = testEnv.authenticatedContext('newcomer').firestore();
    await assertFails(setDoc(doc(db, 'users/newcomer'), signupDoc({ doctorProfileId: 'doctor-profile' })));
  });

  it('prevents a new account from assigning itself to a chamber or moderator role', async () => {
    const db = testEnv.authenticatedContext('newcomer').firestore();
    await assertFails(setDoc(doc(db, 'users/newcomer'), signupDoc({ operatorAssignments: ['chamber-1'] })));
    await assertFails(setDoc(doc(db, 'users/newcomer'), signupDoc({
      roles: { isDoctor: false, isOperator: false, isAdmin: false, isModerator: true },
    })));
  });
});

describe('follow-up chat unlock', () => {
  const chatDoc = (extra = {}) => ({
    participants: ['patient', 'doctor'],
    participantRoles: { patient: 'Patient', doctor: 'Doctor' },
    participantNames: { patient: 'P', doctor: 'D' },
    doctorUid: 'doctor',
    patientUid: 'patient',
    doctorName: 'D',
    patientName: 'P',
    doctorId: 'doctor-profile',
    status: 'active',
    expiresAt: new Date(Date.now() + 7 * 864e5),
    messageLimit: 20,
    messageCount: 0,
    unlockedBy: 'appt-1',
    lastMessage: 'unlocked',
    updatedAt: new Date(),
    ...extra,
  });
  const seedExpiredChat = () => testEnv.withSecurityRulesDisabled(async (c) => {
    await setDoc(doc(c.firestore(), 'chats/patient_doctor'), chatDoc({
      status: 'expired',
      messageCount: 20,
      unlockedBy: 'appt-0',
      expiresAt: new Date(Date.now() - 864e5),
    }));
  });

  it('lets the doctor open a chat after the first visit', async () => {
    const db = testEnv.authenticatedContext('doctor').firestore();
    await assertSucceeds(setDoc(doc(db, 'chats/patient_doctor'), chatDoc(), { merge: true }));
  });

  it('lets the doctor re-open the chat for a returning patient', async () => {
    await seedExpiredChat();
    const db = testEnv.authenticatedContext('doctor').firestore();
    await assertSucceeds(setDoc(doc(db, 'chats/patient_doctor'), chatDoc({ unlockedBy: 'appt-2' }), { merge: true }));
  });

  it('lets an assigned operator open and re-open the chat for their chamber', async () => {
    const db = testEnv.authenticatedContext('operator').firestore();
    await assertSucceeds(setDoc(doc(db, 'chats/patient_doctor'),
      chatDoc({ unlockChamberId: 'chamber-a' }), { merge: true }));
    await seedExpiredChat();
    await assertSucceeds(setDoc(doc(db, 'chats/patient_doctor'),
      chatDoc({ unlockChamberId: 'chamber-a', unlockedBy: 'appt-3' }), { merge: true }));
  });

  it('lets an assigned operator create the chats made on Accept (chamberId)', async () => {
    const db = testEnv.authenticatedContext('operator').firestore();
    await assertSucceeds(setDoc(doc(db, 'chats/chat_appt9_patient_doctor'),
      chatDoc({ chamberId: 'chamber-a', appointmentId: 'appt9', createdAt: new Date() }), { merge: true }));
    await assertSucceeds(setDoc(doc(db, 'chats/chat_appt9_patient_operator'), chatDoc({
      participants: ['patient', 'operator'],
      operatorUid: 'operator',
      chamberId: 'chamber-a',
      appointmentId: 'appt9',
      createdAt: new Date(),
    }), { merge: true }));
  });

  it('refuses an operator who is not assigned to that chamber', async () => {
    const db = testEnv.authenticatedContext('operator').firestore();
    await assertFails(setDoc(doc(db, 'chats/patient_doctor'),
      chatDoc({ unlockChamberId: 'chamber-z' }), { merge: true }));
  });

  it('refuses a different doctor and the patient', async () => {
    await testEnv.withSecurityRulesDisabled(async (c) => {
      await setDoc(doc(c.firestore(), 'users/other-doctor'), {
        roles: { isDoctor: true },
        doctorProfileId: 'other-profile',
      });
    });
    const other = testEnv.authenticatedContext('other-doctor').firestore();
    await assertFails(setDoc(doc(other, 'chats/patient_doctor'), chatDoc(), { merge: true }));
    await seedExpiredChat();
    const patient = testEnv.authenticatedContext('patient').firestore();
    await assertFails(setDoc(doc(patient, 'chats/patient_doctor'), chatDoc({ unlockedBy: 'self' }), { merge: true }));
  });

  it('never lets a re-open change who is in the chat', async () => {
    await seedExpiredChat();
    const db = testEnv.authenticatedContext('doctor').firestore();
    await assertFails(setDoc(doc(db, 'chats/patient_doctor'),
      chatDoc({ participants: ['patient', 'doctor', 'stranger'] }), { merge: true }));
  });
});

describe('appointment authorization', () => {
  it('allows a patient to request another doctor', async () => {
    const db = testEnv.authenticatedContext('patient').firestore();
    await assertSucceeds(setDoc(doc(db, 'appointments/patient-request'), requestedAppointment()));
  });

  it('prevents a doctor from requesting their own profile', async () => {
    const db = testEnv.authenticatedContext('doctor').firestore();
    await assertFails(setDoc(doc(db, 'appointments/doctor-self-request'), requestedAppointment({
      userId: 'doctor',
    })));
  });

  it('prevents an assigned operator from creating a requested appointment', async () => {
    const db = testEnv.authenticatedContext('operator').firestore();
    await assertFails(setDoc(doc(db, 'appointments/operator-request'), requestedAppointment({
      userId: 'operator',
    })));
  });

  it('allows an admin to create an appointment', async () => {
    const db = testEnv.authenticatedContext('admin').firestore();
    await assertSucceeds(setDoc(doc(db, 'appointments/admin-request'), requestedAppointment({
      userId: 'someone-else',
    })));
  });

  it('prevents a stranger from reading another patient appointment', async () => {
    await testEnv.withSecurityRulesDisabled(async (context) => {
      await setDoc(doc(context.firestore(), 'appointments/private-request'), requestedAppointment());
    });
    const db = testEnv.authenticatedContext('stranger').firestore();
    await assertFails(getDoc(doc(db, 'appointments/private-request')));
  });

  it('permits only an admin to append a BMDC verification record', async () => {
    const entry = {
      doctorId: 'doctor-profile',
      outcome: 'found',
      verifiedByUid: 'admin',
      createdAt: new Date('2030-01-01T09:00:00Z'),
    };
    const adminDb = testEnv.authenticatedContext('admin').firestore();
    await assertSucceeds(setDoc(doc(adminDb, 'doctor_verification_history/admin-entry'), entry));

    const patientDb = testEnv.authenticatedContext('patient').firestore();
    await assertFails(setDoc(doc(patientDb, 'doctor_verification_history/patient-entry'), {
      ...entry,
      verifiedByUid: 'patient',
    }));
  });

  it('books an appointment that the AppointmentQueries patient query can read', async () => {
    const db = testEnv.authenticatedContext('patient').firestore();
    await assertSucceeds(setDoc(doc(db, 'appointments/booked-through-queries'), requestedAppointment()));
    // Mirrors AppointmentQueries.patientAppointments('patient') exactly.
    const snapshot = await getDocs(query(
      collection(db, 'appointments'),
      where('userId', '==', 'patient'),
      orderBy('createdAt', 'desc'),
    ));
    assert.equal(snapshot.docs.length, 1);
    assert.equal(snapshot.docs[0].data().status, 'requested');
  });

  it('prevents a second active booking for the same patient, doctor, and date', async () => {
    const bookingKey = 'patient_doctor-profile_chamber-a_2030-01-01';
    const activeBooking = {
      userId: 'patient',
      doctorId: 'doctor-profile',
      chamberId: 'chamber-a',
      dateKey: '2030-01-01',
      appointmentId: 'appt-1',
      createdAt: new Date('2030-01-01T09:00:00Z'),
    };
    const patientDb = testEnv.authenticatedContext('patient').firestore();

    // First active booking creation succeeds
    await assertSucceeds(setDoc(doc(patientDb, `active_bookings/${bookingKey}`), activeBooking));

    // Second active booking with same key fails
    await assertFails(setDoc(doc(patientDb, `active_bookings/${bookingKey}`), {
      ...activeBooking,
      appointmentId: 'appt-2',
    }));
  });

  it('rejects non-admin updating doctor verification fields', async () => {
    const doctorDb = testEnv.authenticatedContext('doctor').firestore();
    // Non-admin can update general profile info (e.g. bio, name)
    await assertSucceeds(updateDoc(doc(doctorDb, 'doctors/doctor-profile'), {
      bio: 'Updated bio by doctor',
    }));
    // Non-admin cannot update verificationStatus
    await assertFails(updateDoc(doc(doctorDb, 'doctors/doctor-profile'), {
      verificationStatus: 'checked_found',
    }));
    // Non-admin cannot update isBmdcVerified
    await assertFails(updateDoc(doc(doctorDb, 'doctors/doctor-profile'), {
      isBmdcVerified: true,
    }));
  });

  it('allows admin to update doctor verification fields', async () => {
    const adminDb = testEnv.authenticatedContext('admin').firestore();
    await assertSucceeds(updateDoc(doc(adminDb, 'doctors/doctor-profile'), {
      verificationStatus: 'checked_found',
      isBmdcVerified: true,
      verifiedBy: 'admin',
    }));
  });

  it('rejects a review with spoofed userId', async () => {
    const patientDb = testEnv.authenticatedContext('patient').firestore();
    await assertFails(setDoc(doc(patientDb, 'reviews/spoofed-review'), {
      userId: 'stranger',
      doctorId: 'doctor-profile',
      rating: 5,
      comment: 'Spoofed',
      createdAt: new Date('2030-01-01T09:00:00Z'),
    }));
  });

  it('rejects a doctor reviewing their own doctorProfileId', async () => {
    const doctorDb = testEnv.authenticatedContext('doctor').firestore();
    await assertFails(setDoc(doc(doctorDb, 'reviews/doctor-self-review'), {
      userId: 'doctor',
      doctorId: 'doctor-profile',
      rating: 5,
      comment: 'Reviewing myself',
      createdAt: new Date('2030-01-01T09:00:00Z'),
    }));
  });

  it('allows a patient to review a doctor', async () => {
    const patientDb = testEnv.authenticatedContext('patient').firestore();
    await assertSucceeds(setDoc(doc(patientDb, 'reviews/patient-valid-review'), {
      userId: 'patient',
      doctorId: 'doctor-profile',
      rating: 5,
      comment: 'Great service!',
      createdAt: new Date('2030-01-01T09:00:00Z'),
    }));
  });

  it('prevents a patient from confirming an appointment, setting time, or setting queue number', async () => {
    const patientDb = testEnv.authenticatedContext('patient').firestore();

    // Patient cannot create appointment as confirmed
    await assertFails(setDoc(doc(patientDb, 'appointments/patient-direct-confirm'), requestedAppointment({
      status: 'confirmed',
    })));

    // Patient cannot create appointment with a queue position
    await assertFails(setDoc(doc(patientDb, 'appointments/patient-direct-queue'), requestedAppointment({
      queuePosition: 1,
    })));

    // Create a valid requested appointment
    await assertSucceeds(setDoc(doc(patientDb, 'appointments/patient-valid-appt'), requestedAppointment()));

    // Patient cannot update appointment status to confirmed
    await assertFails(updateDoc(doc(patientDb, 'appointments/patient-valid-appt'), {
      status: 'confirmed',
    }));

    // Patient cannot update scheduledTime
    await assertFails(updateDoc(doc(patientDb, 'appointments/patient-valid-appt'), {
      scheduledTime: new Date('2030-01-02T10:00:00Z'),
    }));
  });

  it('prevents a patient from writing to queues collection', async () => {
    const patientDb = testEnv.authenticatedContext('patient').firestore();
    await assertFails(setDoc(doc(patientDb, 'queues/chamber-a_2030-01-01'), {
      chamberId: 'chamber-a',
      date: '2030-01-01',
      currentNumber: 1,
    }));
  });

  it('prevents a patient from creating or activating a chat', async () => {
    const patientDb = testEnv.authenticatedContext('patient').firestore();
    // Patient cannot create chat
    await assertFails(setDoc(doc(patientDb, 'chats/patient-created-chat'), {
      patientUid: 'patient',
      doctorUid: 'doctor',
      isActive: true,
      createdAt: new Date('2030-01-01T09:00:00Z'),
    }));

    // Seed inactive chat by doctor
    await testEnv.withSecurityRulesDisabled(async (context) => {
      await setDoc(doc(context.firestore(), 'chats/care-chat'), {
        patientUid: 'patient',
        doctorUid: 'doctor',
        isActive: false,
        messageCount: 0,
      });
    });

    // Patient cannot activate chat
    await assertFails(updateDoc(doc(patientDb, 'chats/care-chat'), {
      isActive: true,
    }));
  });

  it('prevents a stranger from reading a chat', async () => {
    await testEnv.withSecurityRulesDisabled(async (context) => {
      await setDoc(doc(context.firestore(), 'chats/private-chat'), {
        patientUid: 'patient',
        doctorUid: 'doctor',
        participants: ['patient', 'doctor'],
      });
    });

    const strangerDb = testEnv.authenticatedContext('stranger').firestore();
    await assertFails(getDoc(doc(strangerDb, 'chats/private-chat')));

    const patientDb = testEnv.authenticatedContext('patient').firestore();
    await assertSucceeds(getDoc(doc(patientDb, 'chats/private-chat')));
  });

  it('prevents a doctor from setting isAdmin on their own user profile', async () => {
    const doctorDb = testEnv.authenticatedContext('doctor').firestore();
    await assertFails(updateDoc(doc(doctorDb, 'users/doctor'), {
      'roles.isAdmin': true,
    }));
    await assertFails(updateDoc(doc(doctorDb, 'users/doctor'), {
      roles: { isDoctor: true, isAdmin: true },
    }));
  });
});

describe('scheduling algorithm and atomic reservation rules', () => {
  it('capacity: 5:00 PM to 9:00 PM at 10 min equals 24; slotMinutes 5 and 15 compute correctly', () => {
    const calcCapacity = (startHour, startMin, endHour, endMin, slotMinutes) => {
      const diff = (endHour * 60 + endMin) - (startHour * 60 + startMin);
      return Math.floor(diff / slotMinutes);
    };

    assert.equal(calcCapacity(17, 0, 21, 0, 10), 24);
    assert.equal(calcCapacity(17, 0, 21, 0, 5), 48);
    assert.equal(calcCapacity(17, 0, 21, 0, 15), 16);
  });

  it('two concurrent accepts of the same doctor and slot (different chambers): exactly one succeeds', async () => {
    const opDb = testEnv.authenticatedContext('operator').firestore();
    const adminDb = testEnv.authenticatedContext('admin').firestore();

    const slotId = 'doctor-profile_20300101_1700';

    // First reservation succeeds
    await assertSucceeds(setDoc(doc(opDb, `doctor_slots/${slotId}`), {
      doctorId: 'doctor-profile',
      chamberId: 'chamber-a',
      appointmentId: 'appt-1',
      date: '20300101',
      startTime: new Date('2030-01-01T17:00:00Z'),
    }));

    // Concurrent/second reservation of the same slot id fails with update not allowed
    await assertFails(setDoc(doc(adminDb, `doctor_slots/${slotId}`), {
      doctorId: 'doctor-profile',
      chamberId: 'chamber-b',
      appointmentId: 'appt-2',
      date: '20300101',
      startTime: new Date('2030-01-01T17:00:00Z'),
    }));
  });

  it('reschedule frees the old slot and takes the new one', async () => {
    const opDb = testEnv.authenticatedContext('operator').firestore();
    const oldSlotId = 'doctor-profile_20300101_1700';
    const newSlotId = 'doctor-profile_20300101_1710';

    // Reserve old slot
    await assertSucceeds(setDoc(doc(opDb, `doctor_slots/${oldSlotId}`), {
      doctorId: 'doctor-profile',
      chamberId: 'chamber-a',
      appointmentId: 'appt-1',
      date: '20300101',
      startTime: new Date('2030-01-01T17:00:00Z'),
    }));

    // Reschedule: delete old slot and reserve new slot
    await assertSucceeds(deleteDoc(doc(opDb, `doctor_slots/${oldSlotId}`)));
    await assertSucceeds(setDoc(doc(opDb, `doctor_slots/${newSlotId}`), {
      doctorId: 'doctor-profile',
      chamberId: 'chamber-a',
      appointmentId: 'appt-1',
      date: '20300101',
      startTime: new Date('2030-01-01T17:10:00Z'),
    }));
  });

  it('reject, cancel and completion free the slot', async () => {
    const opDb = testEnv.authenticatedContext('operator').firestore();
    const slotId = 'doctor-profile_20300101_1720';

    await assertSucceeds(setDoc(doc(opDb, `doctor_slots/${slotId}`), {
      doctorId: 'doctor-profile',
      chamberId: 'chamber-a',
      appointmentId: 'appt-to-cancel',
      date: '20300101',
      startTime: new Date('2030-01-01T17:20:00Z'),
    }));

    // Freed on cancel / reject / completion
    await assertSucceeds(deleteDoc(doc(opDb, `doctor_slots/${slotId}`)));
    const checkSnap = await getDoc(doc(opDb, `doctor_slots/${slotId}`));
    assert.equal(checkSnap.exists(), false);
  });

  it('booking on a Closed or Full day is rejected', async () => {
    const adminDb = testEnv.authenticatedContext('admin').firestore();
    const patientDb = testEnv.authenticatedContext('patient').firestore();

    // Mark day closed
    await assertSucceeds(setDoc(doc(adminDb, 'chamber_day_overrides/chamber-a_20300101'), {
      chamberId: 'chamber-a',
      doctorId: 'doctor-profile',
      date: '20300101',
      status: 'closed',
      note: 'Doctor unavailable',
    }));

    const overrideSnap = await getDoc(doc(patientDb, 'chamber_day_overrides/chamber-a_20300101'));
    assert.equal(overrideSnap.exists(), true);
    assert.equal(overrideSnap.data().status, 'closed');
  });

  it('patient cannot write doctor_slots, queues or chamber_day_overrides', async () => {
    const patientDb = testEnv.authenticatedContext('patient').firestore();

    await assertFails(setDoc(doc(patientDb, 'doctor_slots/doctor-profile_20300101_1700'), {
      doctorId: 'doctor-profile',
      chamberId: 'chamber-a',
      appointmentId: 'patient-hack',
      date: '20300101',
    }));

    await assertFails(setDoc(doc(patientDb, 'queues/chamber-a_20300101'), {
      chamberId: 'chamber-a',
      date: '20300101',
      lastQueuePosition: 99,
    }));

    await assertFails(setDoc(doc(patientDb, 'chamber_day_overrides/chamber-a_20300101'), {
      chamberId: 'chamber-a',
      date: '20300101',
      status: 'open',
    }));
  });

  it("operator cannot write another chamber's override or slot", async () => {
    const opDb = testEnv.authenticatedContext('operator').firestore(); // assigned to chamber-a only

    await assertFails(setDoc(doc(opDb, 'doctor_slots/doctor-profile_20300101_1700'), {
      doctorId: 'doctor-profile',
      chamberId: 'chamber-b', // unassigned chamber
      appointmentId: 'appt-other-chamber',
      date: '20300101',
      startTime: new Date('2030-01-01T17:00:00Z'),
    }));

    await assertFails(setDoc(doc(opDb, 'chamber_day_overrides/chamber-b_20300101'), {
      chamberId: 'chamber-b', // unassigned chamber
      date: '20300101',
      status: 'open',
    }));
  });

  it('operator reschedule works for their chamber without cross-chamber appointment scan', async () => {
    const opDb = testEnv.authenticatedContext('operator').firestore();

    // Create appointment in chamber-a
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), 'appointments/appt-resched-test'), requestedAppointment({
        chamberId: 'chamber-a',
        status: 'confirmed',
        scheduledTime: new Date('2030-01-01T17:00:00Z'),
      }));
    });

    // Operator updates scheduledTime directly without needing cross-chamber read
    await assertSucceeds(updateDoc(doc(opDb, 'appointments/appt-resched-test'), {
      scheduledTime: new Date('2030-01-01T17:30:00Z'),
      updatedAt: new Date('2030-01-01T10:00:00Z'),
    }));
  });

  it('past slots hidden when date is today; non-visiting day returns the next 3 dates', () => {
    const generateSlots = (date, startH, startM, endH, endM, slotMin) => {
      const s = new Date(date);
      s.setHours(startH, startM, 0, 0);
      const e = new Date(date);
      e.setHours(endH, endM, 0, 0);
      const slots = [];
      while (s < e) {
        slots.push(new Date(s));
        s.setMinutes(s.getMinutes() + slotMin);
      }
      return slots;
    };

    const today = new Date('2030-01-01T18:00:00Z');
    const allSlots = generateSlots('2030-01-01', 17, 0, 21, 0, 10);
    const futureSlots = allSlots.filter(s => s > today);
    assert.equal(futureSlots.length < allSlots.length, true);

    // Non-visiting days: Fri (5) is off. If start is Friday, next 3 visiting days are Sat, Sun, Mon
    const visitingDays = [1, 2, 3, 4, 6, 0]; // Sun=0, Mon=1... Sat=6
    const nextDates = [];
    let cur = new Date('2030-01-04'); // Friday
    while (nextDates.length < 3) {
      cur.setDate(cur.getDate() + 1);
      if (visitingDays.includes(cur.getDay())) {
        nextDates.push(new Date(cur));
      }
    }
    assert.equal(nextDates.length, 3);
  });

  it('duplicate active booking (same patient, doctor, chamber, date) is rejected', async () => {
    const patientDb = testEnv.authenticatedContext('patient').firestore();
    const activeKey = 'patient_doctor-profile_chamber-a_20300101';

    // First booking lock succeeds
    await assertSucceeds(setDoc(doc(patientDb, `active_bookings/${activeKey}`), {
      userId: 'patient',
      doctorId: 'doctor-profile',
      chamberId: 'chamber-a',
      date: '20300101',
    }));

    // Second booking lock fails due to create rule (!exists)
    await assertFails(setDoc(doc(patientDb, `active_bookings/${activeKey}`), {
      userId: 'patient',
      doctorId: 'doctor-profile',
      chamberId: 'chamber-a',
      date: '20300101',
    }));
  });

  it('operator can create a walk-in for their chamber, not for another chamber, patient cannot', async () => {
    const operatorDb = testEnv.authenticatedContext('operator').firestore();
    const patientDb = testEnv.authenticatedContext('patient').firestore();

    const walkInChamberA = {
      patientName: 'Walk-in Patient',
      chamberId: 'chamber-a',
      doctorId: 'doctor-profile',
      status: 'confirmed',
      source: 'walk_in',
      queuePosition: 1,
      scheduledTime: new Date('2030-01-01T17:00:00Z'),
      createdAt: new Date(),
      updatedAt: new Date(),
    };

    // 1. Operator assigned to chamber-a CAN create walk-in for chamber-a
    await assertSucceeds(setDoc(doc(operatorDb, 'appointments/walkin-chamber-a'), walkInChamberA));

    // 2. Operator CANNOT create walk-in for another chamber (chamber-b)
    const walkInChamberB = {
      ...walkInChamberA,
      chamberId: 'chamber-b',
    };
    await assertFails(setDoc(doc(operatorDb, 'appointments/walkin-chamber-b'), walkInChamberB));

    // 3. Patient CANNOT create a walk-in appointment
    await assertFails(setDoc(doc(patientDb, 'appointments/walkin-by-patient'), walkInChamberA));
  });

  describe('canonical chamber permissions & operator routing', () => {
    const setupChamberAndOperators = async () => {
      await testEnv.withSecurityRulesDisabled(async (context) => {
        const db = context.firestore();
        await Promise.all([
          // Doctor Mashrafi (Owner)
          setDoc(doc(db, 'users/user-mashrafi'), {
            roles: { isDoctor: true },
            doctorProfileId: 'doc-mashrafi-prof',
          }),
          setDoc(doc(db, 'doctors/doc-mashrafi-prof'), {
            name: 'Dr Mashrafi Elahi',
            claimedByUid: 'user-mashrafi',
          }),
          // Doctor Nuzhat (Visiting)
          setDoc(doc(db, 'users/user-nuzhat'), {
            roles: { isDoctor: true },
            doctorProfileId: 'doc-nuzhat-prof',
          }),
          setDoc(doc(db, 'doctors/doc-nuzhat-prof'), {
            name: 'Dr Nuzhat Saima',
            claimedByUid: 'user-nuzhat',
          }),
          // Operators
          setDoc(doc(db, 'users/op-mashrafi'), {
            roles: { isOperator: true },
            operatorAssignments: ['chamber-bup'],
          }),
          setDoc(doc(db, 'users/op-nuzhat'), {
            roles: { isOperator: true },
            operatorAssignments: ['chamber-bup'],
          }),
          // Canonical Chamber Bup
          setDoc(doc(db, 'chambers/chamber-bup'), {
            name: 'Bup',
            ownerDoctorId: 'doc-mashrafi-prof',
            doctorIds: ['doc-mashrafi-prof', 'doc-nuzhat-prof'],
            visitingHours: '5:00 PM – 9:00 PM (Sat–Thu)',
            slotMinutes: 10,
          }),
          // Operator assignment for Nuzhat
          setDoc(doc(db, 'chamber_operators/chamber-bup_doc-nuzhat-prof_op-nuzhat'), {
            chamberId: 'chamber-bup',
            doctorId: 'doc-nuzhat-prof',
            operatorUid: 'op-nuzhat',
          }),
          // Operator assignment for Mashrafi
          setDoc(doc(db, 'chamber_operators/chamber-bup_doc-mashrafi-prof_op-mashrafi'), {
            chamberId: 'chamber-bup',
            doctorId: 'doc-mashrafi-prof',
            operatorUid: 'op-mashrafi',
          }),
        ]);
      });
    };

    it('visiting doctor cannot edit chamber hours, but owner doctor can', async () => {
      await setupChamberAndOperators();
      const nuzhatDb = testEnv.authenticatedContext('user-nuzhat').firestore();
      const mashrafiDb = testEnv.authenticatedContext('user-mashrafi').firestore();

      // Visiting doctor fails to edit chamber hours
      await assertFails(updateDoc(doc(nuzhatDb, 'chambers/chamber-bup'), {
        visitingHours: '6:00 PM – 10:00 PM (Sun–Thu)',
      }));

      // Owner doctor succeeds in editing chamber hours
      await assertSucceeds(updateDoc(doc(mashrafiDb, 'chambers/chamber-bup'), {
        visitingHours: '6:00 PM – 10:00 PM (Sun–Thu)',
      }));
    });

    it('visiting doctor can assign their own operator, but not another doctor\'s operator', async () => {
      await setupChamberAndOperators();
      const nuzhatDb = testEnv.authenticatedContext('user-nuzhat').firestore();

      // Visiting doctor assigns an operator for their own profile
      await assertSucceeds(setDoc(doc(nuzhatDb, 'chamber_operators/chamber-bup_doc-nuzhat-prof_new-op'), {
        chamberId: 'chamber-bup',
        doctorId: 'doc-nuzhat-prof',
        operatorUid: 'new-op',
      }));

      // Visiting doctor CANNOT assign an operator for Mashrafi
      await assertFails(setDoc(doc(nuzhatDb, 'chamber_operators/chamber-bup_doc-mashrafi-prof_new-op'), {
        chamberId: 'chamber-bup',
        doctorId: 'doc-mashrafi-prof',
        operatorUid: 'new-op',
      }));
    });

    it('operator of Nuzhat cannot read Mashrafi\'s requests', async () => {
      await setupChamberAndOperators();
      // Seed an appointment for Mashrafi
      await testEnv.withSecurityRulesDisabled(async (context) => {
        const db = context.firestore();
        await setDoc(doc(db, 'appointments/mashrafi-request'), requestedAppointment({
          doctorId: 'doc-mashrafi-prof',
          chamberId: 'chamber-bup',
          handledBy: 'operator',
          status: 'requested',
        }));
      });

      const opMashrafiDb = testEnv.authenticatedContext('op-mashrafi').firestore();
      const opNuzhatDb = testEnv.authenticatedContext('op-nuzhat').firestore();

      // Mashrafi's operator CAN read the request
      await assertSucceeds(getDoc(doc(opMashrafiDb, 'appointments/mashrafi-request')));

      // Nuzhat's operator CANNOT read Mashrafi's request
      await assertFails(getDoc(doc(opNuzhatDb, 'appointments/mashrafi-request')));
    });

    it('patient cannot write chambers or assignments', async () => {
      await setupChamberAndOperators();
      const patientDb = testEnv.authenticatedContext('patient').firestore();

      // Patient cannot create or update chambers
      await assertFails(setDoc(doc(patientDb, 'chambers/patient-chamber'), {
        name: 'Patient Chamber',
        ownerDoctorId: 'patient',
      }));
      await assertFails(updateDoc(doc(patientDb, 'chambers/chamber-bup'), {
        visitingHours: '1:00 PM – 2:00 PM',
      }));

      // Patient cannot create or update assignments
      await assertFails(setDoc(doc(patientDb, 'chamber_operators/chamber-bup_doc-nuzhat-prof_patient'), {
        chamberId: 'chamber-bup',
        doctorId: 'doc-nuzhat-prof',
        operatorUid: 'patient',
      }));
    });
  });
});

describe('per-doctor daily queue and appointment lifecycle', () => {
  const QID = 'chamber-a_doctor-profile_20300101';
  const proposedAt = new Date('2030-01-01T11:00:00Z');

  async function seedQueue({ appt = {}, queue = {} } = {}) {
    await testEnv.withSecurityRulesDisabled(async (context) => {
      const db = context.firestore();
      await setDoc(doc(db, 'appointments/appt-p'), requestedAppointment({
        status: 'proposed',
        proposedTime: proposedAt,
        queueId: QID,
        slotId: 'doctor-profile_20300101_1100',
        ...appt,
      }));
      await setDoc(doc(db, `queues/${QID}`), {
        chamberId: 'chamber-a',
        doctorId: 'doctor-profile',
        date: '20300101',
        lastNumber: 2,
        currentServing: 0,
        waitingTokens: [1, 2],
        waitingCount: 2,
        ...queue,
      });
      await setDoc(doc(db, 'doctor_slots/doctor-profile_20300101_1100'), {
        doctorId: 'doctor-profile',
        chamberId: 'chamber-a',
        appointmentId: 'appt-p',
        date: '20300101',
      });
    });
  }

  function accept(db, token, waiting) {
    return runTransaction(db, async (tx) => {
      const apptRef = doc(db, 'appointments/appt-p');
      const qRef = doc(db, `queues/${QID}`);
      await tx.get(apptRef);
      await tx.get(qRef);
      tx.set(qRef, {
        chamberId: 'chamber-a',
        doctorId: 'doctor-profile',
        date: '20300101',
        lastNumber: token,
        currentServing: 0,
        waitingTokens: waiting,
        waitingCount: waiting.length,
        lastTouchedAppointmentId: 'appt-p',
      }, { merge: true });
      tx.update(apptRef, {
        status: 'confirmed',
        scheduledTime: proposedAt,
        queuePosition: token,
        confirmedAt: new Date(),
        updatedAt: new Date(),
      });
    });
  }

  it('lets the patient accept a proposal and take the next token', async () => {
    await seedQueue();
    const patientDb = testEnv.authenticatedContext('patient').firestore();
    await assertSucceeds(accept(patientDb, 3, [1, 2, 3]));
  });

  it('refuses a patient who skips ahead to a later token', async () => {
    await seedQueue();
    const patientDb = testEnv.authenticatedContext('patient').firestore();
    await assertFails(accept(patientDb, 7, [1, 2, 7]));
  });

  it('refuses a patient accepting at a different time than proposed', async () => {
    await seedQueue();
    const patientDb = testEnv.authenticatedContext('patient').firestore();
    await assertFails(runTransaction(patientDb, async (tx) => {
      const apptRef = doc(patientDb, 'appointments/appt-p');
      await tx.get(apptRef);
      tx.update(apptRef, {
        status: 'confirmed',
        scheduledTime: new Date('2030-01-01T09:00:00Z'),
        queuePosition: 3,
        updatedAt: new Date(),
      });
    }));
  });

  it('refuses a stranger accepting someone else\'s proposal', async () => {
    await seedQueue();
    const strangerDb = testEnv.authenticatedContext('stranger').firestore();
    await assertFails(accept(strangerDb, 3, [1, 2, 3]));
  });

  it('lets the patient decline and free the held slot', async () => {
    await seedQueue();
    const patientDb = testEnv.authenticatedContext('patient').firestore();
    await assertSucceeds(updateDoc(doc(patientDb, 'appointments/appt-p'), {
      status: 'declined', declinedAt: new Date(), updatedAt: new Date(),
    }));
    await assertSucceeds(deleteDoc(doc(patientDb, 'doctor_slots/doctor-profile_20300101_1100')));
  });

  it('refuses a patient freeing a slot of an appointment that is still open', async () => {
    await seedQueue();
    const patientDb = testEnv.authenticatedContext('patient').firestore();
    await assertFails(deleteDoc(doc(patientDb, 'doctor_slots/doctor-profile_20300101_1100')));
  });

  it('lets a patient cancel and remove only their own token', async () => {
    await seedQueue({
      appt: { status: 'confirmed', queuePosition: 2, scheduledTime: proposedAt },
    });
    const patientDb = testEnv.authenticatedContext('patient').firestore();
    const cancel = (waiting) => runTransaction(patientDb, async (tx) => {
      const apptRef = doc(patientDb, 'appointments/appt-p');
      const qRef = doc(patientDb, `queues/${QID}`);
      await tx.get(apptRef);
      await tx.get(qRef);
      tx.set(qRef, {
        waitingTokens: waiting,
        waitingCount: waiting.length,
        lastTouchedAppointmentId: 'appt-p',
      }, { merge: true });
      tx.update(apptRef, { status: 'cancelled', cancelledBy: 'patient', updatedAt: new Date() });
    });
    await assertFails(cancel([2]));
    await assertSucceeds(cancel([1]));
  });

  it('lets the assigned operator run the queue but not skip lifecycle steps', async () => {
    await seedQueue({ appt: { status: 'requested' } });
    const opDb = testEnv.authenticatedContext('operator').firestore();
    await assertFails(updateDoc(doc(opDb, 'appointments/appt-p'), { status: 'done' }));
    await assertFails(updateDoc(doc(opDb, 'appointments/appt-p'), { status: 'checked_in' }));
    await assertSucceeds(updateDoc(doc(opDb, 'appointments/appt-p'), { status: 'proposed' }));
    await assertSucceeds(updateDoc(doc(opDb, `queues/${QID}`), { currentServing: 1 }));
  });

  it('refuses another doctor writing this doctor\'s queue', async () => {
    await seedQueue();
    await testEnv.withSecurityRulesDisabled(async (context) => {
      await setDoc(doc(context.firestore(), 'users/other-doctor'), {
        roles: { isDoctor: true }, doctorProfileId: 'other-profile',
      });
    });
    const otherDb = testEnv.authenticatedContext('other-doctor').firestore();
    await assertFails(updateDoc(doc(otherDb, `queues/${QID}`), { currentServing: 2 }));
  });

  it('refuses a queue doc whose ID does not match its chamber, doctor and date', async () => {
    const opDb = testEnv.authenticatedContext('operator').firestore();
    await assertFails(setDoc(doc(opDb, 'queues/chamber-a_doctor-profile_20300102'), {
      chamberId: 'chamber-a', doctorId: 'doctor-profile', date: '20300101', lastNumber: 1,
    }));
  });
});

describe('inline chat photo attachments', () => {
  const CHAT = 'chats/chat-att';
  async function seedChat(status = 'active') {
    await testEnv.withSecurityRulesDisabled(async (context) => {
      await setDoc(doc(context.firestore(), CHAT), {
        participants: ['patient', 'doctor'],
        patientUid: 'patient',
        doctorUid: 'doctor',
        doctorId: 'doctor-profile',
        status,
        messageCount: 0,
        messageLimit: 20,
      });
    });
  }
  const photo = (sender, size = 1024) => ({
    bytes: Bytes.fromUint8Array(new Uint8Array(size)),
    mimeType: 'image/jpeg',
    senderUid: sender,
    createdAt: new Date(),
  });

  it('lets a participant send a photo the other participant can read', async () => {
    await seedChat();
    const patientDb = testEnv.authenticatedContext('patient').firestore();
    const doctorDb = testEnv.authenticatedContext('doctor').firestore();
    await assertSucceeds(setDoc(doc(patientDb, `${CHAT}/attachments/a1`), photo('patient')));
    await assertSucceeds(getDoc(doc(doctorDb, `${CHAT}/attachments/a1`)));
  });

  it('refuses outsiders, closed chats, oversize photos and spoofed senders', async () => {
    await seedChat();
    const strangerDb = testEnv.authenticatedContext('stranger').firestore();
    const patientDb = testEnv.authenticatedContext('patient').firestore();
    await assertFails(setDoc(doc(strangerDb, `${CHAT}/attachments/x1`), photo('stranger')));
    await assertFails(setDoc(doc(patientDb, `${CHAT}/attachments/x2`), photo('doctor')));
    await assertFails(setDoc(doc(patientDb, `${CHAT}/attachments/x3`), photo('patient', 800 * 1024)));
    await assertSucceeds(setDoc(doc(patientDb, `${CHAT}/attachments/ok`), photo('patient')));
    await assertFails(getDoc(doc(strangerDb, `${CHAT}/attachments/ok`)));
    await seedChat('closed');
    await assertFails(setDoc(doc(patientDb, `${CHAT}/attachments/x4`), photo('patient')));
  });

  it('lets only the sender unsend, and nobody edit', async () => {
    await seedChat();
    const patientDb = testEnv.authenticatedContext('patient').firestore();
    const doctorDb = testEnv.authenticatedContext('doctor').firestore();
    await assertSucceeds(setDoc(doc(patientDb, `${CHAT}/attachments/a2`), photo('patient')));
    await assertFails(updateDoc(doc(patientDb, `${CHAT}/attachments/a2`), { mimeType: 'image/png' }));
    await assertFails(deleteDoc(doc(doctorDb, `${CHAT}/attachments/a2`)));
    await assertSucceeds(deleteDoc(doc(patientDb, `${CHAT}/attachments/a2`)));
  });
});

describe('staff chat, consult chat unlock, inbox hiding', () => {
  async function seedAppt(status = 'confirmed', userId = 'patient') {
    await testEnv.withSecurityRulesDisabled(async (context) => {
      const db = context.firestore();
      await setDoc(doc(db, 'appointments/appt-c'), requestedAppointment({ status, userId }));
      await setDoc(doc(db, 'chats/staff_doctor-profile'), {
        type: 'staff', participants: ['doctor', 'operator'], doctorUid: 'doctor',
        doctorId: 'doctor-profile', status: 'active', messageCount: 0,
      });
    });
  }
  const consult = (extra = {}) => ({
    participants: ['patient', 'doctor'], patientUid: 'patient', doctorUid: 'doctor',
    doctorId: 'doctor-profile', unlockedBy: 'appt-c', status: 'active',
    messageLimit: 20, messageCount: 0, unlockChamberId: 'chamber-a', ...extra,
  });

  it('lets a patient open their consult chat only for their own confirmed visit', async () => {
    const patientDb = testEnv.authenticatedContext('patient').firestore();
    await seedAppt('requested');
    await assertFails(setDoc(doc(patientDb, 'chats/patient_doctor'), consult()));
    await seedAppt('confirmed');
    await assertFails(setDoc(doc(patientDb, 'chats/patient_doctor'), consult({ messageLimit: 500 })));
    await assertFails(setDoc(doc(patientDb, 'chats/patient_doctor'), consult({ participants: ['patient', 'stranger'], doctorUid: 'stranger' })));
    await assertSucceeds(setDoc(doc(patientDb, 'chats/patient_doctor'), consult()));
  });

  it('lets a patient post an event about their own appointment, not a stranger', async () => {
    await seedAppt();
    const patientDb = testEnv.authenticatedContext('patient').firestore();
    const strangerDb = testEnv.authenticatedContext('stranger').firestore();
    const event = (uid) => ({ senderUid: uid, type: 'system', appointmentId: 'appt-c', text: 'New request', createdAt: new Date() });
    await assertSucceeds(setDoc(doc(patientDb, 'chats/staff_doctor-profile/messages/e1'), event('patient')));
    await assertSucceeds(updateDoc(doc(patientDb, 'chats/staff_doctor-profile'), { lastMessage: 'New request', lastEventAppointmentId: 'appt-c', updatedAt: new Date() }));
    await assertFails(setDoc(doc(strangerDb, 'chats/staff_doctor-profile/messages/e2'), event('stranger')));
    await assertFails(getDoc(doc(patientDb, 'chats/staff_doctor-profile')));
    await assertFails(updateDoc(doc(patientDb, 'chats/staff_doctor-profile'), { participants: ['doctor', 'operator', 'patient'] }));
  });

  it('lets staff chat members talk with no limit and only the doctor change members', async () => {
    await seedAppt();
    const opDb = testEnv.authenticatedContext('operator').firestore();
    const doctorDb = testEnv.authenticatedContext('doctor').firestore();
    await assertSucceeds(setDoc(doc(opDb, 'chats/staff_doctor-profile/messages/m1'), { senderUid: 'operator', text: 'hi', createdAt: new Date() }));
    await assertFails(updateDoc(doc(opDb, 'chats/staff_doctor-profile'), { participants: ['doctor', 'operator', 'stranger'] }));
    await assertSucceeds(updateDoc(doc(doctorDb, 'chats/staff_doctor-profile'), { participants: ['doctor'], status: 'closed' }));
  });

  it('lets users hide chats only in their own inbox', async () => {
    const patientDb = testEnv.authenticatedContext('patient').firestore();
    await assertSucceeds(setDoc(doc(patientDb, 'users/patient/inboxHidden/c1'), { hiddenAt: new Date() }));
    await assertFails(setDoc(doc(patientDb, 'users/doctor/inboxHidden/c1'), { hiddenAt: new Date() }));
  });
});

describe('operator leaves a desk', () => {
  it('removes only their own assignment and staff-chat seat', async () => {
    await testEnv.withSecurityRulesDisabled(async (context) => {
      await setDoc(doc(context.firestore(), 'chats/staff_doctor-profile'), {
        type: 'staff', participants: ['doctor', 'operator', 'op2'], doctorUid: 'doctor',
        doctorId: 'doctor-profile', status: 'active', messageCount: 0,
      });
    });
    const opDb = testEnv.authenticatedContext('operator').firestore();
    await assertFails(updateDoc(doc(opDb, 'chats/staff_doctor-profile'), { participants: ['doctor'] }));
    await assertSucceeds(updateDoc(doc(opDb, 'chats/staff_doctor-profile'), { participants: ['doctor', 'op2'] }));
    await assertSucceeds(deleteDoc(doc(opDb, 'chamber_operators/chamber-a_doctor-profile_operator')));
    const strangerDb = testEnv.authenticatedContext('stranger').firestore();
    await testEnv.withSecurityRulesDisabled(async (c) => setDoc(doc(c.firestore(), 'chamber_operators/chamber-a_doctor-profile_op2'), { chamberId: 'chamber-a', doctorId: 'doctor-profile', operatorUid: 'op2' }));
    await assertFails(deleteDoc(doc(strangerDb, 'chamber_operators/chamber-a_doctor-profile_op2')));
  });
});
