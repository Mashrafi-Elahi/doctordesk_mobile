// Rebuilds the search fields (searchText, searchTokens, searchPrefixes) on
// every doctor doc whose fields are missing or stale, e.g. doctors created or
// claimed in the app. Same rules as lib/services/doctor_search_index.dart:
// per-word prefixes, so "mashrafi" or "saima" match without "Dr".
//
//   node scripts/backfill_search_index.js           # dry run
//   node scripts/backfill_search_index.js --apply   # write

const admin = require('firebase-admin');
const { initializeAdmin } = require('./lib/admin_init');

const applyChanges = process.argv.includes('--apply');

function normalize(value) {
  return String(value || '').toLowerCase().replace(/[^a-z0-9\u0980-\u09ff]+/g, ' ').trim();
}

const titleTokens = ['dr', 'doctor', 'doc', 'ডা', 'ডাক্তার'];
const nameAliases = {
  md: ['mohammad', 'mohammed', 'muhammad'],
  mohammad: ['md'],
  mohammed: ['md'],
  muhammad: ['md'],
};
const specialtyAbbreviations = {
  ent: ['otolaryngology', 'otolaryngologist', 'ear nose throat', 'ইএনটি'],
  otolaryngology: ['ent', 'ear nose throat', 'ইএনটি'],
  gyn: ['gynecology', 'obstetrics', 'gynecologist', 'obgyn', 'obs', 'gynae'],
  gynae: ['gynecology', 'obstetrics', 'gynecologist', 'obgyn', 'obs', 'gyn'],
  obgyn: ['gynecology', 'obstetrics', 'gynecologist', 'gynae', 'obs'],
  gynecology: ['gyn', 'gynae', 'obgyn', 'obs', 'gynecologist'],
  ortho: ['orthopedics', 'orthopedic', 'orthopedist'],
  orthopedics: ['ortho', 'orthopedic', 'orthopedist'],
  cardio: ['cardiology', 'cardiologist', 'heart'],
  cardiology: ['cardio', 'cardiologist', 'heart'],
  derm: ['dermatology', 'dermatologist', 'skin', 'derma'],
  skin: ['dermatology', 'dermatologist', 'derm'],
  dermatology: ['derm', 'derma', 'skin', 'dermatologist'],
  peds: ['pediatrics', 'pediatrician', 'ped', 'paed', 'child'],
  pediatrics: ['peds', 'ped', 'paed', 'child', 'pediatrician'],
  eye: ['ophthalmology', 'ophthalmologist', 'ophth'],
  ophthalmology: ['eye', 'ophth', 'ophthalmologist'],
  dent: ['dentistry', 'dentist', 'dental'],
  dentistry: ['dent', 'dental', 'dentist'],
  med: ['general medicine', 'medicine', 'internal medicine', 'gp'],
  gp: ['general medicine', 'medicine', 'med'],
  'general medicine': ['med', 'gp', 'medicine'],
  neuro: ['neurology', 'neurologist'],
  neurology: ['neuro', 'neurologist'],
  psych: ['psychiatry', 'psychiatrist'],
  psychiatry: ['psych', 'psychiatrist'],
  onco: ['oncology', 'oncologist', 'cancer'],
  oncology: ['onco', 'oncologist'],
  gastro: ['gastroenterology', 'liver'],
  gastroenterology: ['gastro', 'liver'],
  nephro: ['nephrology', 'kidney'],
  nephrology: ['nephro', 'kidney'],
  pulmo: ['pulmonology', 'chest'],
  pulmonology: ['pulmo', 'chest'],
  endo: ['endocrinology', 'diabetes'],
  endocrinology: ['endo', 'diabetes'],
};

function valuesFor(doctor) {
  const chambers = Array.isArray(doctor.chambers) ? doctor.chambers : [];
  const specialities = Array.isArray(doctor.specialities) ? doctor.specialities : [];
  const base = [
    doctor.name, doctor.designation,
    ...specialities, ...(doctor.education || []),
    ...(doctor.concentrations || []),
    ...titleTokens,
    ...chambers.flatMap((chamber) => [chamber.hospitalName, chamber.area, chamber.location]),
  ].filter(Boolean);

  const nameWords = normalize(doctor.name).split(' ').filter(Boolean);
  for (const w of nameWords) {
    if (nameAliases[w]) base.push(...nameAliases[w]);
  }
  for (const s of specialities) {
    const sNorm = normalize(s);
    if (specialtyAbbreviations[sNorm]) base.push(...specialtyAbbreviations[sNorm]);
    for (const w of sNorm.split(' ').filter(Boolean)) {
      if (specialtyAbbreviations[w]) base.push(...specialtyAbbreviations[w]);
    }
  }
  return base;
}

function searchFields(doctor) {
  const searchText = normalize(valuesFor(doctor).join(' '));
  const searchTokens = [...new Set(searchText.split(' ').filter(Boolean))];
  const searchPrefixes = new Set();
  for (const token of searchTokens) {
    for (let length = 2; length <= token.length && length <= 16; length += 1) {
      searchPrefixes.add(token.slice(0, length));
    }
  }
  return { searchText, searchTokens, searchPrefixes: [...searchPrefixes] };
}

async function main() {
  initializeAdmin(admin);
  const db = admin.firestore();
  const snapshot = await db.collection('doctors').get();
  const updates = snapshot.docs
      .map((doc) => ({ doc, fields: searchFields(doc.data()) }))
      .filter(({ doc, fields }) => {
        const current = doc.data();
        return current.searchText !== fields.searchText ||
            JSON.stringify(current.searchTokens || []) !== JSON.stringify(fields.searchTokens) ||
            JSON.stringify(current.searchPrefixes || []) !== JSON.stringify(fields.searchPrefixes);
      });
  console.log(`Prepared search fields for ${snapshot.size} doctor profiles; ${updates.length} need updates.`);
  if (!applyChanges) {
    console.log('Dry run only. Re-run with --apply to write search fields.');
    return;
  }

  let batch = db.batch();
  let count = 0;
  for (const update of updates) {
    batch.set(update.doc.ref, update.fields, { merge: true });
    count += 1;
    if (count % 450 === 0) {
      await batch.commit();
      if (count < updates.length) batch = db.batch();
      console.log(`Indexed ${count}/${updates.length} doctors.`);
    }
  }
  if (count % 450 !== 0) await batch.commit();
  console.log(`Indexed ${count} doctors successfully.`);
}

main().catch((error) => {
  console.error('Search-index backfill failed:', error.message || error);
  process.exit(1);
});
