import 'dart:isolate';
import 'scheduling_service.dart';
import 'queue_service.dart';
import 'chamber_resolver.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'dart:math';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import '../models/doctor.dart';
import 'doctor_search_index.dart';
import 'geofire_utils.dart';
import 'notification_service.dart';
import 'chat_service.dart';
import 'auth_service.dart';

/// Cloud Firestore service providing complete data access for DoctorDesk.
/// Matches the method signatures of [ApiService] for transparent backend switching.
class FirestoreService {
  static final FirebaseFirestore _db = FirebaseFirestore.instance;
  static final FirebaseAuth _auth = FirebaseAuth.instance;

  static FirebaseFirestore get db => _db;
  static FirebaseAuth get auth => _auth;

  // =========================================================================
  // DOCTORS DIRECTORY & SEARCH
  // =========================================================================

  static List<Map<String, dynamic>>? _cachedBundledMaps;

  /// Loads and caches raw maps for the 6,000+ bundled APK doctors with precomputed searchText
  static Future<List<Map<String, dynamic>>> _getIndexedBundledMaps() async {
    if (_cachedBundledMaps != null && _cachedBundledMaps!.isNotEmpty) {
      return _cachedBundledMaps!;
    }
    final docs = await getBundledDoctors();
    // ~6,000 doctors: indexing them on the UI thread froze the screen.
    _cachedBundledMaps = await Isolate.run(() => docs.map((d) {
          final m = d.toJson();
          m['_id'] = d.id;
          m['searchText'] = DoctorSearchIndex.fieldsFor(m)['searchText'];
          return m;
        }).toList());
    return _cachedBundledMaps!;
  }

  static bool _matchesSpecialtyFilter(List<String> docSpecs, String filter) {
    final normFilter = DoctorSearchIndex.normalize(filter);
    if (normFilter.isEmpty || normFilter == 'all') return true;
    final filterAbbrevs = <String>{
      normFilter,
      ...(DoctorSearchIndex.specialtyAbbreviations[normFilter] ?? const [])
          .map(DoctorSearchIndex.normalize),
    };
    for (final ft in DoctorSearchIndex.tokens(normFilter)) {
      final ab = DoctorSearchIndex.specialtyAbbreviations[ft];
      if (ab != null) {
        filterAbbrevs.addAll(ab.map(DoctorSearchIndex.normalize));
      }
    }
    for (final s in docSpecs) {
      final normS = DoctorSearchIndex.normalize(s);
      if (normS == normFilter ||
          normS.contains(normFilter) ||
          normFilter.contains(normS)) {
        return true;
      }
      final sToks = DoctorSearchIndex.tokens(normS);
      if (sToks.any(filterAbbrevs.contains) || filterAbbrevs.contains(normS)) {
        return true;
      }
    }
    return false;
  }

  /// Fetches doctors with pagination, optional specialty filter, and indexed
  /// multilingual token search across names, specialties, symptoms, chambers, and degrees.
  /// Uses the 6,000+ bundled APK directory directly to avoid hitting Firestore 50k read limits.
  static final Map<String, List<DocumentSnapshot>> _fetchCursors = {};

  /// Fetches doctors with pagination. Firestore `doctors` is the primary source of truth.
  /// Uses cursor-based pagination (startAfterDocument). If offline or Firestore fails,
  /// falls back to local cache and bundled list, merging by doctor ID (Firestore wins).
  static Future<List<Doctor>>? _claimedDoctors;
  static DateTime _claimedDoctorsAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// Every claimed (bookable) doctor. Few enough to load in one query, and
  /// needed so they can lead page 1 instead of sitting wherever their name
  /// sorts in the paginated list.
  /// After an approval, list the newly claimed doctor right away.
  static void invalidateClaimedDoctors() => _claimedDoctors = null;

  static Future<List<Doctor>> _loadClaimedDoctors() {
    if (_claimedDoctors == null ||
        DateTime.now().difference(_claimedDoctorsAt) > const Duration(minutes: 1)) {
      _claimedDoctorsAt = DateTime.now();
      _claimedDoctors = _db
          .collection('doctors')
          // isNotEqualTo: null is ignored by the Dart SDK; any non-empty
          // string sorts after ''.
          .where('claimedByUid', isGreaterThan: '')
          .limit(300)
          .get()
          .then((snap) => snap.docs.map((d) {
                final data = Map<String, dynamic>.from(d.data());
                data['_id'] = d.id;
                data['id'] = d.id;
                return Doctor.fromJson(data);
              }).where((d) => !d.isHidden && !d.isDeleted && d.isClaimedProfile).toList())
          .catchError((Object e) {
        debugPrint('Claimed doctors query failed: $e');
        _claimedDoctors = null;
        return <Doctor>[];
      });
    }
    return _claimedDoctors!;
  }

  /// Claimed doctors matching the current filter/search, best first.
  static Future<List<Doctor>> _claimedMatches(String search, String? speciality) async {
    final claimed = await _loadClaimedDoctors();
    var matches = claimed.where((d) =>
        speciality == null || _matchesSpecialtyFilter(d.specialities, speciality)).toList();
    if (search.isNotEmpty) {
      final ranked = DoctorSearchIndex.rank(matches.map((d) => d.toJson()), search);
      matches = ranked.map(Doctor.fromJson).toList();
    }
    return Doctor.sortForListing(matches);
  }

  static Future<Map<String, dynamic>> fetchDoctors({
    int page = 1,
    int limit = 20,
    String? search,
    String? speciality,
  }) async {
    final normSearch = search?.trim() ?? '';
    final normSpec = (speciality != null && speciality.trim().isNotEmpty && speciality != 'All')
        ? speciality.trim()
        : null;
    final queryKey = '${normSpec ?? ""}|$normSearch|$limit';

    try {
      Query<Map<String, dynamic>> query = _db.collection('doctors');

      if (normSpec != null) {
        query = query.where('specialities', arrayContains: normSpec);
      }

      if (normSearch.isNotEmpty && normSpec == null) {
        final prefixes = DoctorSearchIndex.queryPrefixes(normSearch);
        if (prefixes.isNotEmpty) {
          query = query.where('searchPrefixes', arrayContainsAny: prefixes.take(10).toList());
        }
      }

      if (normSearch.isEmpty) {
        query = query.orderBy('name_lower', descending: false);
      }

      if (page > 1) {
        final cursors = _fetchCursors[queryKey];
        if (cursors != null && cursors.length >= page - 1) {
          query = query.startAfterDocument(cursors[page - 2]);
        }
      }

      query = query.limit(limit);
      final snapshot = await query.get();

      if (snapshot.docs.isNotEmpty) {
        _fetchCursors.putIfAbsent(queryKey, () => []);
        final cursors = _fetchCursors[queryKey]!;
        if (cursors.length < page) {
          cursors.add(snapshot.docs.last);
        } else {
          cursors[page - 1] = snapshot.docs.last;
        }

        final firestoreDoctors = snapshot.docs.map((docSnap) {
          final data = Map<String, dynamic>.from(docSnap.data());
          data['_id'] = docSnap.id;
          data['id'] = docSnap.id;
          return Doctor.fromJson(data);
        }).where((d) => !d.isHidden && !d.isDeleted).toList();

        List<Doctor> resultDocs = firestoreDoctors;
        if (normSearch.isNotEmpty) {
          final rawMaps = firestoreDoctors.map((d) => d.toJson()).toList();
          final ranked = DoctorSearchIndex.rank(rawMaps, normSearch);
          resultDocs = ranked.map(Doctor.fromJson).toList();
        }

        // Claimed doctors lead page 1 and are left out of later pages.
        final claimed = await _claimedMatches(normSearch, normSpec);
        final claimedIds = claimed.map((d) => d.id).toSet();
        resultDocs = Doctor.sortForListing(
            resultDocs.where((d) => !claimedIds.contains(d.id)));
        if (page == 1) resultDocs = [...claimed, ...resultDocs];

        if (page == 1 && normSearch.isEmpty && normSpec == null) {
          _cacheDiscoveryDoctorsLocally(resultDocs);
        }

        final hasMore = snapshot.docs.length >= limit;
        return {
          'doctors': resultDocs,
          'total': hasMore ? (page * limit) + limit : ((page - 1) * limit) + resultDocs.length,
          'totalPages': hasMore ? page + 1 : page,
          'isOffline': false,
        };
      } else if (page > 1) {
        return {
          'doctors': <Doctor>[],
          'total': (page - 1) * limit,
          'totalPages': page - 1,
          'isOffline': false,
        };
      }
      // If page == 1 and Firestore returns 0 docs (e.g. initial state before bundled upload),
      // seamlessly fall through to fallback so discovery remains populated.
    } catch (e) {
      debugPrint('Firestore fetchDoctors online failed, falling back to cache/bundled: $e');
    }

    final fallback = await _fetchDoctorsFallback(
      page: page,
      limit: limit,
      search: search,
      speciality: speciality,
    );
    // A name only claimed doctors have (e.g. "mashrafi") finds nothing in the
    // search index and lands here; they must still lead page 1.
    if (page == 1) {
      try {
        final claimed = await _claimedMatches(normSearch, normSpec);
        if (claimed.isNotEmpty) {
          final ids = claimed.map((d) => d.id).toSet();
          fallback['doctors'] = [
            ...claimed,
            ...List<Doctor>.from(fallback['doctors'] as List).where((d) => !ids.contains(d.id)),
          ];
        }
      } catch (_) {}
    }
    return fallback;
  }

  static Future<void> _cacheDiscoveryDoctorsLocally(List<Doctor> docs) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = docs.map((d) => d.toJson()).toList();
      await prefs.setString('cached_discovery_doctors', jsonEncode(list));
    } catch (_) {}
  }

  static Future<List<Doctor>> _getLocalCachedDoctors() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final str = prefs.getString('cached_discovery_doctors');
      if (str != null && str.isNotEmpty) {
        final List decoded = jsonDecode(str);
        return decoded.map((j) => Doctor.fromJson(Map<String, dynamic>.from(j as Map))).toList();
      }
    } catch (_) {}
    return [];
  }

  static Future<Map<String, dynamic>> _fetchDoctorsFallback({
    int page = 1,
    int limit = 20,
    String? search,
    String? speciality,
  }) async {
    final cachedDocs = await _getLocalCachedDoctors();
    final allMaps = await _getIndexedBundledMaps();
    final Map<String, Map<String, dynamic>> byId = {};

    for (final m in allMaps) {
      final id = (m['_id'] ?? m['id'] ?? '').toString();
      byId[id] = Map<String, dynamic>.from(m);
    }

    // Cached Firestore docs merge with bundled, Firestore wins
    for (final cd in cachedDocs) {
      final cJson = cd.toJson();
      if (byId.containsKey(cd.id)) {
        byId[cd.id]!.addAll(cJson);
      } else {
        byId[cd.id] = cJson;
      }
    }

    final prefs = await SharedPreferences.getInstance();
    final hiddenIds = (prefs.getStringList('hidden_doctor_ids') ?? []).toSet();
    final deletedIds = (prefs.getStringList('deleted_doctor_ids') ?? []).toSet();

    List<Map<String, dynamic>> records = byId.values.where((data) {
      final id = (data['_id'] ?? data['id'] ?? '').toString();
      if (hiddenIds.contains(id) || deletedIds.contains(id)) return false;
      if (data['hidden'] == true || data['isHidden'] == true || data['isDeleted'] == true) return false;
      return true;
    }).toList();

    if (speciality != null &&
        speciality.trim().isNotEmpty &&
        speciality != 'All') {
      records = records.where((data) {
        final specs = (data['specialities'] as List? ?? const [])
            .map((e) => e.toString())
            .toList();
        return _matchesSpecialtyFilter(specs, speciality);
      }).toList();
    }

    final hasSearch = search?.trim().isNotEmpty == true;
    if (hasSearch) {
      records = DoctorSearchIndex.rank(records, search!.trim());
    }

    final all = Doctor.sortForListing(records.map(Doctor.fromJson));
    final totalCount = all.length;
    final totalPages = (totalCount / limit).ceil().clamp(1, 9999);
    final startIndex = (page - 1) * limit;
    final doctors = startIndex < totalCount
        ? all.sublist(startIndex, (startIndex + limit).clamp(0, totalCount))
        : <Doctor>[];

    return {
      'doctors': doctors,
      'total': totalCount,
      'totalPages': totalPages,
      'isOffline': true,
    };
  }

  /// Fetches a doctor by document ID from bundled APK directory and merges Firestore dynamic updates (claim, reviews, chambers).
  static Future<Doctor> fetchDoctorById(String id) async {
    Doctor? baseDoctor;
    try {
      final bundled = await getBundledDoctors();
      final normalizedId = id.replaceFirst('doctor_', 'doc_');
      for (final doc in bundled) {
        if (doc.id == id ||
            doc.id == normalizedId ||
            doc.id == 'doc_$id' ||
            doc.id == 'doctor_$id') {
          baseDoctor = doc;
          break;
        }
      }
    } catch (_) {}

    try {
      final docRef = _db.collection('doctors').doc(id);
      var snapshot = await docRef.get();

      if (!snapshot.exists && !id.startsWith('doctor_')) {
        snapshot = await _db.collection('doctors').doc('doctor_$id').get();
      }

      if (snapshot.exists && snapshot.data() != null) {
        final data = Map<String, dynamic>.from(snapshot.data()!);
        data['_id'] = snapshot.id;
        if (baseDoctor != null) {
          final mergedMap = baseDoctor.toJson();
          mergedMap.addAll(data);
          if (!data.containsKey('chambers') || (data['chambers'] as List?)?.isEmpty == true) {
            mergedMap['chambers'] = baseDoctor.chambers.map((c) => c.toJson()).toList();
          }
          return Doctor.fromJson(mergedMap);
        }
        return Doctor.fromJson(data);
      }
    } catch (e) {
      debugPrint('Firestore fetchDoctorById error: $e');
    }

    if (baseDoctor != null) return baseDoctor;
    throw Exception('Failed to load doctor profile');
  }

  static Future<String> addDoctor({
    required String name,
    required List<String> specialities,
    String? designation,
    double experienceYears = 5.0,
    List<String> education = const ['MBBS'],
    String? bmdcRegNumber,
    List<Map<String, dynamic>> chambers = const [],
    String? phone,
    String? applicantUid,
  }) async {
    final normalizedName = name.trim();
    if (normalizedName.isEmpty) {
      throw ArgumentError('Doctor name is required.');
    }
    final normalizedSpecialities = specialities
        .map((speciality) => speciality.trim())
        .where((speciality) => speciality.isNotEmpty)
        .toList();
    if (normalizedSpecialities.isEmpty) {
      throw ArgumentError('At least one speciality is required.');
    }
    final normalizedBmdc = bmdcRegNumber?.trim() ?? '';
    final duplicateQuery = normalizedBmdc.isNotEmpty
        ? _db
            .collection('doctors')
            .where('bmdcRegNumber', isEqualTo: normalizedBmdc)
            .limit(1)
        : _db
            .collection('doctors')
            .where('name_lower', isEqualTo: normalizedName.toLowerCase())
            .limit(1);
    final duplicate = await duplicateQuery.get();

    DocumentReference<Map<String, dynamic>> docRef;
    if (applicantUid != null && applicantUid.trim().isNotEmpty) {
      final existingClaim = await _db
          .collection('doctors')
          .where('claimedByUid', isEqualTo: applicantUid.trim())
          .limit(1)
          .get();
      docRef = existingClaim.docs.isNotEmpty
          ? existingClaim.docs.first.reference
          : _db.collection('doctors').doc('doctor_${applicantUid.trim()}');
    } else {
      docRef = _db.collection('doctors').doc();
    }

    if (duplicate.docs.isNotEmpty && duplicate.docs.first.id != docRef.id) {
      throw StateError(
          'A doctor with the same name or BMDC number already exists.');
    }

    final isClaimed = applicantUid != null && applicantUid.trim().isNotEmpty;
    final fullName = normalizedName.startsWith('Dr.')
        ? normalizedName
        : 'Dr. $normalizedName';
    final data = <String, dynamic>{
      'name': fullName,
      'name_lower': fullName.toLowerCase(),
      'specialities': normalizedSpecialities,
      'designation': designation ?? 'Consultant',
      'experienceYears': experienceYears,
      'education': education,
      'bmdcRegNumber': normalizedBmdc,
      'bmdcNumber': normalizedBmdc,
      'isBmdcVerified': isClaimed && normalizedBmdc.isNotEmpty,
      'verificationStatus': isClaimed && normalizedBmdc.isNotEmpty ? 'verified' : 'unverified',
      'isClaimed': isClaimed,
      'claimStatus': isClaimed ? 'claimed' : 'unclaimed',
      if (isClaimed) 'claimedByUid': applicantUid.trim(),
      'status': 'active',
      'ratingAverage': 0.0,
      'ratingCount': 0,
      'reviewCount': 0,
      'phone': phone ?? '',
      'chambers': chambers.isNotEmpty
          ? chambers
          : [
              {
                'hospitalName': 'Bup Medical',
                'area': 'Mirpur',
                'location': 'Dhaka',
              }
            ],
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
      ...DoctorSearchIndex.fieldsFor({
        'name': normalizedName,
        'designation': designation ?? 'Consultant',
        'specialities': normalizedSpecialities,
        'education': education,
        'chambers': chambers,
      }),
    };

    if (isClaimed) {
      final userRef = _db.collection('users').doc(applicantUid.trim());
      final userSnap = await userRef.get();
      final userData = userSnap.data() ?? {};
      final appData = Map<String, dynamic>.from(
          (userData['doctorApplication'] as Map?) ?? const {});

      final batch = _db.batch();
      batch.set(docRef, data, SetOptions(merge: true));
      batch.set(
        userRef,
        {
          'roles': {
            ...Map<String, dynamic>.from(
                (userData['roles'] as Map?) ?? const {}),
            'isDoctor': true,
          },
          'chamberCount': chambers.isNotEmpty ? chambers.length : 1,
          'doctorProfileId': docRef.id,
          'isBmdcVerified': normalizedBmdc.isNotEmpty,
          if (normalizedBmdc.isNotEmpty) 'bmdcRegNumber': normalizedBmdc,
          if (phone != null && phone.trim().isNotEmpty)
            'phone': phone.trim(),
          'doctorApplication': {
            ...appData,
            'status': 'approved',
            'name': normalizedName,
            if (normalizedBmdc.isNotEmpty) 'bmdcNumber': normalizedBmdc,
            if (phone != null && phone.trim().isNotEmpty)
              'phone': phone.trim(),
            'reviewedAt': FieldValue.serverTimestamp(),
            'reviewedByUid': _auth.currentUser?.uid,
          },
        },
        SetOptions(merge: true),
      );
      await batch.commit();
      return docRef.id;
    }

    // If no applicantUid was given, check if a user with this phone exists to link
    if (phone != null && phone.trim().isNotEmpty) {
      try {
        final matchSnap = await _db
            .collection('users')
            .where('phone', isEqualTo: phone.trim())
            .limit(1)
            .get();
        if (matchSnap.docs.isNotEmpty) {
          final matchedDoc = matchSnap.docs.first;
          final matchedUid = matchedDoc.id;
          final matchedUser = matchedDoc.data();
          data['isClaimed'] = true;
          data['claimedByUid'] = matchedUid;
          data['isBmdcVerified'] = normalizedBmdc.isNotEmpty;

          final batch = _db.batch();
          batch.set(docRef, data);
          batch.set(
            matchedDoc.reference,
            {
              'roles': {
                ...Map<String, dynamic>.from(
                    (matchedUser['roles'] as Map?) ?? const {}),
                'isDoctor': true,
              },
              'chamberCount': chambers.isNotEmpty ? chambers.length : 1,
              'doctorProfileId': docRef.id,
              'isBmdcVerified': normalizedBmdc.isNotEmpty,
              if (normalizedBmdc.isNotEmpty) 'bmdcRegNumber': normalizedBmdc,
              'doctorApplication': {
                ...Map<String, dynamic>.from(
                    (matchedUser['doctorApplication'] as Map?) ?? const {}),
                'status': 'approved',
                'name': normalizedName,
                if (normalizedBmdc.isNotEmpty) 'bmdcNumber': normalizedBmdc,
                'reviewedAt': FieldValue.serverTimestamp(),
                'reviewedByUid': _auth.currentUser?.uid,
              },
            },
            SetOptions(merge: true),
          );
          await batch.commit();
          return docRef.id;
        }
      } catch (_) {}
    }

    await docRef.set(data);
    return docRef.id;
  }

  static Future<void> deleteDoctor(String doctorId) async {
    await _db.collection('doctors').doc(doctorId).delete();
  }

  static List<Map<String, dynamic>>? _cachedSpecialitiesList;

  /// Computes specialities list and doctor counts directly from the 6,000+ bundled APK dataset (0 Firestore reads).
  static Future<List<Map<String, dynamic>>> fetchSpecialities() async {
    if (_cachedSpecialitiesList != null && _cachedSpecialitiesList!.isNotEmpty) {
      return _cachedSpecialitiesList!;
    }
    try {
      final docs = await getBundledDoctors();
      final Map<String, int> counts = {};
      for (final d in docs) {
        for (final s in d.specialities) {
          final clean = s.trim();
          if (clean.isNotEmpty) {
            counts[clean] = (counts[clean] ?? 0) + 1;
          }
        }
      }
      final list = counts.entries
          .map((e) => <String, dynamic>{'speciality': e.key, 'count': e.value})
          .toList()
        ..sort((a, b) => (b['count'] as int).compareTo(a['count'] as int));

      _cachedSpecialitiesList = list;
      return list;
    } catch (e) {
      debugPrint('Error computing bundled specialities: $e');
    }

    return const [
      {'speciality': 'GYNECOLOGIST & OBSTETRICIAN', 'count': 704},
      {'speciality': 'MEDICINE SPECIALIST', 'count': 579},
      {'speciality': 'CARDIOLOGIST', 'count': 380},
      {'speciality': 'PEDIATRICIAN', 'count': 339},
      {'speciality': 'GENERAL SURGEON', 'count': 284},
      {'speciality': 'DERMATOLOGIST', 'count': 283},
      {'speciality': 'OTOLARYNGOLOGISTS (ENT)', 'count': 270},
      {'speciality': 'ORTHOPEDIC SURGEON', 'count': 235},
      {'speciality': 'OPHTHALMOLOGIST', 'count': 231},
      {'speciality': 'NEUROLOGIST', 'count': 117},
      {'speciality': 'DENTIST', 'count': 120},
      {'speciality': 'ENDOCRINOLOGIST', 'count': 129},
    ];
  }

  /// Nearby doctors search across all 6,000+ bundled APK doctors using exact Haversine distance (0 Firestore reads).
  static Future<List<Doctor>> fetchNearbyDoctors({
    required double lat,
    required double lng,
    int radiusKm = 8,
    String? speciality,
    String? areaFilter,
    int page = 1,
    int limit = 20,
  }) async {
    final bundled = await _getIndexedBundledMaps();
    // Claimed doctors live in Firestore with their real chambers (e.g. Bup
    // Medical); the bundled directory alone never lists them.
    final claimed = await _loadClaimedDoctors();
    final claimedIds = claimed.map((d) => d.id).toSet();
    final allMaps = [
      ...claimed.map((d) => {...d.toJson(), '_id': d.id}),
      ...bundled.where((m) => !claimedIds.contains((m['_id'] ?? m['id'] ?? '').toString())),
    ];
    final normArea = areaFilter?.trim().toLowerCase();

    final List<Doctor> matched = await Isolate.run(() {
      final List<Doctor> list = [];
      for (final data in allMaps) {
        final specs = (data['specialities'] as List? ?? const [])
            .map((e) => e.toString())
            .toList();
        if (speciality != null &&
            speciality.isNotEmpty &&
            speciality != 'All' &&
            !_matchesSpecialtyFilter(specs, speciality)) {
          continue;
        }

        final chambers = (data['chambers'] as List? ?? const [])
            .whereType<Map>()
            .map((c) => Map<String, dynamic>.from(c))
            .toList();

        double? bestDist;
        Map<String, dynamic>? bestChamber;
        for (final ch in chambers) {
          final chLat = (ch['lat'] as num?)?.toDouble();
          final chLng = (ch['lng'] as num?)?.toDouble();
          final chArea = (ch['area'] ?? ch['location'] ?? '').toString().toLowerCase();
          final chHosp = (ch['hospitalName'] ?? ch['name'] ?? '').toString().toLowerCase();

          bool isAreaMatch = false;
          if (normArea != null && normArea.isNotEmpty && normArea != 'all') {
            final cleanNorm = normArea.replaceAll('l', '');
            final cleanArea = chArea.replaceAll('l', '');
            if (chArea.contains(normArea) || chHosp.contains(normArea) || cleanArea.contains(cleanNorm)) {
              isAreaMatch = true;
            }
          }

          if (chLat != null && chLng != null && (chLat != 0.0 || chLng != 0.0)) {
            final dist = GeofireUtils.distanceBetweenKm([lat, lng], [chLat, chLng]);
            if ((dist <= radiusKm || isAreaMatch) && (bestDist == null || dist < bestDist)) {
              bestDist = dist;
              bestChamber = ch;
            }
          } else if (isAreaMatch) {
            bestChamber ??= ch;
          }
        }

        if (bestChamber != null) {
          final copy = Map<String, dynamic>.from(data);
          copy['distance'] = bestDist;
          copy['chamber'] = bestChamber;
          list.add(Doctor.fromJson(copy));
        }
      }

      list.sort((a, b) => (a.distance ?? 999.0).compareTo(b.distance ?? 999.0));
      return Doctor.sortForListing(list);
    });

    final startIndex = (page - 1) * limit;
    if (startIndex >= matched.length) return [];
    final endIndex = (startIndex + limit > matched.length)
        ? matched.length
        : startIndex + limit;

    return matched.sublist(startIndex, endIndex);
  }

  // =========================================================================
  // GEOCODING (Direct Nominatim client with BD filter)
  // =========================================================================

  /// Direct OpenStreetMap Nominatim geocoding with 1-req/sec safety header
  static Future<List<Map<String, dynamic>>> fetchGeocodeSuggestions(
      String query) async {
    try {
      final uri = Uri.parse(
        'https://nominatim.openstreetmap.org/search?q=${Uri.encodeComponent(query)}&format=json&limit=2&countrycodes=bd',
      );
      final response = await http.get(uri, headers: {
        'User-Agent':
            'DoctorDesk-Flutter/1.0 (student project, contact: dev@doctordesk.bd)',
      }).timeout(const Duration(seconds: 4));

      if (response.statusCode == 200) {
        final List data = jsonDecode(response.body);
        return data.map((item) {
          return {
            'displayName': item['display_name'] ?? '',
            'lat': double.tryParse(item['lat']?.toString() ?? '0') ?? 0.0,
            'lng': double.tryParse(item['lon']?.toString() ?? '0') ?? 0.0,
          };
        }).toList();
      }
    } catch (e) {
      debugPrint('Direct Nominatim geocode error: $e');
    }
    return [];
  }

  // =========================================================================
  // JOURNAL & MOOD
  // =========================================================================

  static Future<Map<String, dynamic>?> fetchTodayFeeling() async {
    try {
      final uid = _auth.currentUser?.uid;
      if (uid == null) return null;

      final startOfDay = DateTime.now();
      final startTimestamp =
          DateTime(startOfDay.year, startOfDay.month, startOfDay.day);

      final snapshot = await _db
          .collection('journal')
          .where('userId', isEqualTo: uid)
          .where('createdAt',
              isGreaterThanOrEqualTo: Timestamp.fromDate(startTimestamp))
          .orderBy('createdAt', descending: true)
          .limit(1)
          .get();

      if (snapshot.docs.isNotEmpty) {
        return snapshot.docs.first.data();
      }
    } catch (e) {
      debugPrint('Firestore fetchTodayFeeling error: $e');
    }
    return null;
  }

  static Future<bool> logFeeling({
    required String feeling,
    String? note,
    String? gratitudeText,
  }) async {
    try {
      final uid = _auth.currentUser?.uid ?? 'guest';
      await _db.collection('journal').add({
        'userId': uid,
        'feeling': feeling.toLowerCase(),
        'note': note ?? '',
        'gratitudeText': gratitudeText ?? '',
        'createdAt': FieldValue.serverTimestamp(),
      });
      return true;
    } catch (e) {
      debugPrint('Firestore logFeeling error: $e');
      return false;
    }
  }

  static Future<List<Map<String, dynamic>>> fetchJournalEntries() async {
    try {
      final uid = _auth.currentUser?.uid;
      if (uid == null) return [];

      final snapshot = await _db
          .collection('journal')
          .where('userId', isEqualTo: uid)
          .orderBy('createdAt', descending: true)
          .limit(30)
          .get();

      return snapshot.docs.map((d) {
        final data = d.data();
        data['id'] = d.id;
        final ts = data['createdAt'];
        if (ts is Timestamp) {
          data['createdAt'] = ts.toDate().toIso8601String();
        }
        return data;
      }).toList();
    } catch (e) {
      debugPrint('Firestore fetchJournalEntries error: $e');
      return [];
    }
  }

  // =========================================================================
  // REVIEWS & BMDC CLAIMS
  // =========================================================================

  static Stream<List<Map<String, dynamic>>> reviewsStream(String doctorId) {
    return _db
        .collection('reviews')
        .where('doctorId', isEqualTo: doctorId)
        .snapshots()
        .map((snapshot) {
      final list = snapshot.docs.map((d) {
        final data = d.data();
        data['id'] = d.id;
        final ts = data['createdAt'];
        if (ts is Timestamp) {
          data['createdAt'] = ts.toDate().toIso8601String();
        }
        return data;
      }).toList();

      list.sort((a, b) {
        final aDate = a['createdAt']?.toString() ?? '';
        final bDate = b['createdAt']?.toString() ?? '';
        return bDate.compareTo(aDate);
      });

      return list;
    });
  }

  static Future<List<Map<String, dynamic>>> fetchReviews(
      String doctorId) async {
    try {
      final snapshot = await _db
          .collection('reviews')
          .where('doctorId', isEqualTo: doctorId)
          .get();

      final list = snapshot.docs.map((d) {
        final data = d.data();
        data['id'] = d.id;
        final ts = data['createdAt'];
        if (ts is Timestamp) {
          data['createdAt'] = ts.toDate().toIso8601String();
        }
        return data;
      }).toList();

      list.sort((a, b) {
        final aDate = a['createdAt']?.toString() ?? '';
        final bDate = b['createdAt']?.toString() ?? '';
        return bDate.compareTo(aDate);
      });

      return list;
    } catch (e) {
      debugPrint('Firestore fetchReviews error: $e');
      return [];
    }
  }

  static Future<void> deleteReview(String doctorId, String reviewId) async {
    try {
      await _db.collection('reviews').doc(reviewId).delete();
      final allReviews = await fetchReviews(doctorId);
      if (allReviews.isEmpty) {
        await _db.collection('doctors').doc(doctorId).set({
          'ratingAverage': 0.0,
          'ratingCount': 0,
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      } else {
        double sum = 0;
        int count = 0;
        for (final r in allReviews) {
          final rScore = (r['rating'] as num?)?.toDouble() ?? 0.0;
          final hasProof = r['proofImageUrl'] != null &&
              r['proofImageUrl'].toString().isNotEmpty;
          final weight = hasProof ? 2 : 1;
          sum += (rScore * weight);
          count += weight;
        }
        final avg = count > 0 ? (sum / count) : 0.0;
        await _db.collection('doctors').doc(doctorId).set({
          'ratingAverage': double.parse(avg.toStringAsFixed(1)),
          'ratingCount': allReviews.length,
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      }
    } catch (e) {
      debugPrint('Error deleting review: $e');
      rethrow;
    }
  }

  static Future<Map<String, dynamic>> submitReview(
    String doctorId, {
    required String patientUid,
    required int rating,
    String comment = '',
    String? proofImageUrl,
  }) async {
    final reviewDocId = '${doctorId}_$patientUid';
    final name = _auth.currentUser?.displayName?.isNotEmpty == true
        ? _auth.currentUser!.displayName!
        : (_auth.currentUser?.email?.split('@').first ?? 'Patient');

    String role = 'patient';
    try {
      final userSnap = await _db.collection('users').doc(patientUid).get();
      final roles = (userSnap.data()?['roles'] as Map?)?.cast<String, dynamic>() ?? {};
      if (roles['isDoctor'] == true) {
        role = 'doctor';
      } else if (roles['isOperator'] == true) {
        role = 'operator';
      }
    } catch (_) {}

    final reviewData = <String, dynamic>{
      'doctorId': doctorId,
      'userId': patientUid,
      'patientUid': patientUid,
      'raterName': name,
      'raterRole': role,
      'rating': rating,
      'comment': comment,
      'proofImageUrl': proofImageUrl ?? '',
      'isProofVerified': proofImageUrl != null && proofImageUrl.isNotEmpty,
      'createdAt': FieldValue.serverTimestamp(),
    };

    await _db
        .collection('reviews')
        .doc(reviewDocId)
        .set(reviewData, SetOptions(merge: true));

    // Update doctor's aggregate rating in Firestore
    try {
      final allReviews = await fetchReviews(doctorId);
      if (allReviews.isNotEmpty) {
        double sum = 0;
        int count = 0;
        for (final r in allReviews) {
          final rScore = (r['rating'] as num?)?.toDouble() ?? 0.0;
          final hasProof = r['proofImageUrl'] != null &&
              r['proofImageUrl'].toString().isNotEmpty;
          final weight = hasProof ? 2 : 1;
          sum += (rScore * weight);
          count += weight;
        }
        final avg = count > 0 ? (sum / count) : 0.0;
        await _db.collection('doctors').doc(doctorId).set({
          'ratingAverage': double.parse(avg.toStringAsFixed(1)),
          'ratingCount': allReviews.length,
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      }
    } catch (e) {
      debugPrint('Error updating doctor aggregate rating: $e');
    }

    try {
      if (patientUid.isNotEmpty) {
        await NotificationService.createNotification(
          userId: patientUid,
          title: 'Review submitted',
          body: 'Your $rating-star rating and review have been recorded.',
          type: 'review',
          relatedId: doctorId,
        );
      }
      final docSnap = await _db.collection('doctors').doc(doctorId).get();
      if (docSnap.exists) {
        final claimedBy = docSnap.data()?['claimedByUid'] as String?;
        if (claimedBy != null && claimedBy.isNotEmpty && claimedBy != patientUid) {
          await NotificationService.createNotification(
            userId: claimedBy,
            title: 'New review received',
            body: 'A patient submitted a $rating-star review on your profile.',
            type: 'review',
            relatedId: doctorId,
          );
        }
      }
    } catch (e) {
      debugPrint('Error triggering review notification: $e');
    }

    return {
      'doctorId': doctorId,
      'rating': rating,
      'comment': comment,
    };
  }

  static Future<bool> checkCanReview(String doctorId, String patientUid,
      {Map<String, dynamic>? doctorData}) async {
    if (patientUid.isEmpty) return false;
    final claimedBy = doctorData?['claimedByUid'] ?? doctorData?['userId'];
    if (claimedBy != null && claimedBy == patientUid) {
      return false; // Doctor cannot review their own profile
    }
    return true;
  }

  /// Finds the doctor a pasted Profile ID refers to (the app shows bundled
  /// doctors as doctor_N while Firestore stores doc_N, as fetchDoctorById
  /// handles). Null if none; otherwise its real id and 'claimed'/'unclaimed'.
  static Future<({String id, String status})?> resolveDoctorForClaim(String raw) async {
    final id = raw.trim();
    if (id.isEmpty) return null;
    final candidates = <String>{
      id,
      id.replaceFirst('doctor_', 'doc_'),
      id.replaceFirst('doc_', 'doctor_'),
      if (!id.startsWith('doc')) ...['doc_$id', 'doctor_$id'],
    };
    for (final candidate in candidates) {
      final snap = await _db.collection('doctors').doc(candidate).get();
      if (!snap.exists) continue;
      final uid = (snap.data()?['claimedByUid'] ?? '').toString();
      return (id: candidate, status: uid.isNotEmpty ? 'claimed' : 'unclaimed');
    }
    return null;
  }

  /// Submits a claim request for a doctor profile.
  /// Creates a document in `claim_requests` with status 'pending'.
  /// No role is granted automatically (requires admin review & approval).
  static Future<Map<String, dynamic>> claimDoctor(
    String doctorId, {
    required String bmdcRegNumber,
    required String claimedByUid,
    String? certificateImageUrl,
  }) async {
    Doctor? doctor;
    try {
      doctor = await fetchDoctorById(doctorId);
    } catch (_) {}

    final doctorName = doctor?.name ?? 'Dr. Specialist';
    final speciality = doctor?.specialities.isNotEmpty == true ? doctor!.specialities.first : 'General Medicine';
    final chamberName = doctor?.chambers.isNotEmpty == true ? doctor!.chambers.first.hospitalName : '';

    String applicantName = '';
    String applicantEmail = '';
    try {
      final userSnap = await _db.collection('users').doc(claimedByUid).get();
      if (userSnap.exists) {
        final uData = userSnap.data() ?? {};
        applicantName = (uData['name'] ?? uData['displayName'] ?? '').toString();
        applicantEmail = (uData['email'] ?? '').toString();
      }
    } catch (_) {}

    final claimDocRef = await _db.collection('claim_requests').add({
      'doctorId': doctorId,
      'doctorName': doctorName,
      'speciality': speciality,
      'chamberName': chamberName,
      'applicantUid': claimedByUid,
      'applicantName': applicantName,
      'applicantEmail': applicantEmail,
      'bmdcNumber': bmdcRegNumber,
      'certificateImageUrl': certificateImageUrl ?? '',
      'status': 'pending',
      'submittedAt': FieldValue.serverTimestamp(),
    });

    // Notice: NO ROLE IS GRANTED AUTOMATICALLY. Admin must review and approve.

    try {
      await NotificationService.createNotification(
        userId: claimedByUid,
        title: 'Claim Request Submitted',
        body: 'Your claim request for $doctorName has been submitted for admin verification.',
        type: 'claim_pending',
        relatedId: doctorId,
      );
    } catch (_) {}

    return {
      'claimRequestId': claimDocRef.id,
      'doctorId': doctorId,
      'status': 'pending',
    };
  }

  // =========================================================================
  // USER PROFILES & ROLES SYNC
  // =========================================================================

  static Future<Map<String, dynamic>?> fetchUserProfile(String uid) async {
    try {
      final docSnap = await _db.collection('users').doc(uid).get();
      if (docSnap.exists) {
        final data = docSnap.data()!;
        data['uid'] = docSnap.id;
        final roles = Map<String, dynamic>.from(
            (data['roles'] as Map<String, dynamic>?) ?? {});

        // Check if user is an admin directly from Firebase (admins collection, roles in Firestore, or Auth custom claims)
        final adminDoc = await _db.collection('admins').doc(uid).get();
        bool isMasterAdmin = adminDoc.exists || roles['isAdmin'] == true;

        if (!isMasterAdmin && _auth.currentUser?.uid == uid) {
          try {
            final tokenResult = await _auth.currentUser?.getIdTokenResult();
            if (tokenResult?.claims?['admin'] == true ||
                tokenResult?.claims?['isAdmin'] == true) {
              isMasterAdmin = true;
            }
          } catch (_) {}
        }

        roles['isAdmin'] = isMasterAdmin;

        // A doctor role is tied to a claimed doctor profile. This prevents a
        // stale role flag or a normal applicant from receiving appointments.
        if (roles['isDoctor'] == true) {
          if (data['doctorProfileId'] != null) {
            data['doctorProfileId'] = data['doctorProfileId'].toString();
          }
          if (data['chamberCount'] == null || (data['chamberCount'] as num) <= 0) {
            data['chamberCount'] = 1;
          }
        }

        if (roles['isOperator'] == true &&
            ((data['operatorAssignments'] as List?)?.isNotEmpty != true)) {
          // If assigned to a chamber or desk, keep operator active
        }
        data['roles'] = roles;

        return data;
      }
    } catch (e) {
      debugPrint('Firestore fetchUserProfile error: $e');
    }
    return null;
  }

  // =========================================================================
  // OPERATOR DESK MANAGEMENT
  // =========================================================================

  static Future<List<Map<String, dynamic>>> fetchRegisteredUsers({int limit = 50}) async {
    try {
      final snap = await _db.collection('users').limit(limit).get();
      return snap.docs.map((d) {
        final data = d.data();
        data['uid'] = d.id;
        return data;
      }).toList();
    } catch (e) {
      debugPrint('Error fetching registered users: $e');
      return [];
    }
  }

  static Future<void> assignChamberOperator({
    required String doctorId,
    required String chamberId,
    required String operatorUid,
    required String operatorName,
    required String operatorEmail,
  }) async {
    // 1. Resolve human-readable chamber name and doctor name
    final docRef = _db.collection('doctors').doc(doctorId);
    final docSnap = await docRef.get();
    String chamberName = chamberId;
    String docName = 'Doctor';

    if (docSnap.exists) {
      final data = docSnap.data() ?? {};
      docName = (data['name'] ?? 'Doctor').toString();
      final rawChambers = (data['chambers'] as List?) ?? [];
      for (final c in rawChambers) {
        if (c is Map) {
          final cid = (c['id'] ?? c['hospitalName'] ?? c['name'] ?? '').toString();
          if (cid == chamberId) {
            chamberName = (c['name'] ?? c['hospitalName'] ?? chamberId).toString();
            break;
          }
        }
      }
    }
    if (chamberName == chamberId) {
      if (chamberId == 'demo-chamber') {
        chamberName = 'Popular Central Diagnostic Desk';
      } else if (chamberId == 'chamber-bup-1') {
        chamberName = 'BUP Medical Center Desk';
      } else if (chamberId.startsWith('chamber-')) {
        chamberName = 'Chamber Desk (${chamberId.substring(8, 12.clamp(0, chamberId.length))})';
      }
    }

    // 2. Batch write: save top-level chambers doc, chamber_operators mapping, and user doc
    final batch = _db.batch();

    final chamberRef = _db.collection('chambers').doc(chamberId);
    batch.set(chamberRef, {
      'id': chamberId,
      'chamberId': chamberId,
      'name': chamberName,
      'chamberName': chamberName,
      'ownerDoctorId': doctorId,
      'doctorIds': FieldValue.arrayUnion([doctorId]),
      'doctorId': doctorId,
      'doctorName': docName,
      // Chambers are public: who runs the desk lives only in chamber_operators.
      'hasOperator': true,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    final mappingId = '${chamberId}_${doctorId}_$operatorUid';
    final mappingRef = _db.collection('chamber_operators').doc(mappingId);
    batch.set(mappingRef, {
      'chamberId': chamberId,
      'doctorId': doctorId,
      'doctorName': docName,
      'chamberName': chamberName,
      'operatorUid': operatorUid,
      'operatorName': operatorName,
      'assignedByDoctorUid': _auth.currentUser?.uid,
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    final userRef = _db.collection('users').doc(operatorUid);
    batch.set(userRef, {
      'roles': {
        'isOperator': true,
      },
      'operatorAssignments': FieldValue.arrayUnion([chamberId]),
      'assignedChambers': FieldValue.arrayUnion([
        {
          'chamberId': chamberId,
          'chamberName': chamberName,
          'doctorId': doctorId,
          'doctorName': docName,
        }
      ]),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    await batch.commit();
    await _syncStaffChatFor(doctorId);

    // 4. Update the doctor document's chambers list
    if (docSnap.exists) {
      final data = docSnap.data() ?? {};
      final rawChambers = (data['chambers'] as List?) ?? [];
      final updatedChambers = rawChambers.map((c) {
        final cMap = Map<String, dynamic>.from(c as Map);
        final cName = cMap['id'] ?? cMap['hospitalName'] ?? cMap['name'];
        if (cName == chamberId || cMap['id'] == chamberId || cMap['hospitalName'] == chamberId) {
          cMap['hasOperator'] = true;
        }
        return cMap;
      }).toList();
      await docRef.update({'chambers': updatedChambers});
    }

    // 5. Re-route pending requests for this doctor at this chamber to operator
    try {
      final pendingAppts = await _db
          .collection('appointments')
          .where('chamberId', isEqualTo: chamberId)
          .where('doctorId', isEqualTo: doctorId)
          .where('status', isEqualTo: 'requested')
          .get();

      if (pendingAppts.docs.isNotEmpty) {
        final apptBatch = _db.batch();
        for (final apptDoc in pendingAppts.docs) {
          apptBatch.update(apptDoc.reference, {
            'handledBy': 'operator',
            'operatorUid': operatorUid,
            'updatedAt': FieldValue.serverTimestamp(),
          });
        }
        await apptBatch.commit();
      }
    } catch (_) {}

    // 6. Send in-app notification
    try {
      await NotificationService.createNotification(
        userId: operatorUid,
        title: 'Desk Operator Assigned',
        body: 'You have been assigned as desk operator for $chamberName.',
        type: 'system',
        relatedId: chamberId,
      );
    } catch (_) {}
  }

  /// The signed-in operator leaves a doctor's desk at one chamber: their
  /// assignment goes, and so does their seat in the doctor's staff chat.
  static Future<void> leaveDesk({required String chamberId, required String doctorId}) async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) throw StateError('Sign in first.');
    await _db.collection('chamber_operators').doc('${chamberId}_${doctorId}_$uid').delete();
    try {
      await _db.collection('chats').doc(ChatService.staffChatId(doctorId)).update({
        'participants': FieldValue.arrayRemove([uid]),
        'participantNames.$uid': FieldValue.delete(),
        'participantRoles.$uid': FieldValue.delete(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      debugPrint('Staff chat leave skipped: $e');
    }
  }

  /// Keeps the doctor's one staff chat in step with chamber_operators.
  static Future<void> _syncStaffChatFor(String doctorId) async {
    try {
      final docSnap = await _db.collection('doctors').doc(doctorId).get();
      final doctorUid = (docSnap.data()?['claimedByUid'] ?? '').toString();
      if (doctorUid.isEmpty) return;
      final ops = await _db.collection('chamber_operators').where('doctorId', isEqualTo: doctorId).get();
      await ChatService.syncStaffChat(
        doctorId: doctorId,
        doctorUid: doctorUid,
        doctorName: (docSnap.data()?['name'] ?? 'Doctor').toString(),
        operators: {
          for (final d in ops.docs)
            (d.data()['operatorUid'] ?? '').toString(): (d.data()['operatorName'] ?? 'Desk').toString(),
        },
        chamberId: ops.docs.isEmpty ? null : (ops.docs.first.data()['chamberId'] ?? '').toString(),
      );
    } catch (e) {
      debugPrint('Staff chat sync failed for $doctorId: $e');
    }
  }

  static Future<void> removeChamberOperator({
    required String doctorId,
    required String chamberId,
    required String operatorUid,
  }) async {
    final batch = _db.batch();

    // 1. Delete mapping from chamber_operators
    final mappingId = '${chamberId}_${doctorId}_$operatorUid';
    final mappingRef = _db.collection('chamber_operators').doc(mappingId);
    batch.delete(mappingRef);

    // 2. Update user assignments and roles in same batch
    if (operatorUid.isNotEmpty) {
      final userRef = _db.collection('users').doc(operatorUid);
      final userSnap = await userRef.get();
      if (userSnap.exists) {
        final currentAssignments = List<String>.from((userSnap.data()?['operatorAssignments'] as List?) ?? []);
        currentAssignments.remove(chamberId);
        batch.set(userRef, {
          'operatorAssignments': currentAssignments,
          'updatedAt': FieldValue.serverTimestamp(),
          if (currentAssignments.isEmpty)
            'roles': {
              'isOperator': false,
            },
        }, SetOptions(merge: true));
      }
    }

    await batch.commit();
    await _syncStaffChatFor(doctorId);

    // 3. Update doctor chambers
    final docRef = _db.collection('doctors').doc(doctorId);
    final docSnap = await docRef.get();
    if (docSnap.exists) {
      final data = docSnap.data() ?? {};
      final rawChambers = (data['chambers'] as List?) ?? [];
      final updatedChambers = rawChambers.map((c) {
        final cMap = Map<String, dynamic>.from(c as Map);
        final cName = cMap['id'] ?? cMap['hospitalName'] ?? cMap['name'];
        if (cName == chamberId || cMap['id'] == chamberId || cMap['operatorUid'] == operatorUid) {
          cMap['hasOperator'] = false;
          cMap['operatorUid'] = null;
          cMap['operatorName'] = null;
          cMap['operatorEmail'] = null;
        }
        return cMap;
      }).toList();
      await docRef.update({'chambers': updatedChambers});
    }

    // 4. Re-route pending requests for this doctor back to doctor if no other operator assigned
    try {
      final otherOps = await _db
          .collection('chamber_operators')
          .where('chamberId', isEqualTo: chamberId)
          .where('doctorId', isEqualTo: doctorId)
          .limit(1)
          .get();

      if (otherOps.docs.isEmpty) {
        final pendingAppts = await _db
            .collection('appointments')
            .where('chamberId', isEqualTo: chamberId)
            .where('doctorId', isEqualTo: doctorId)
            .where('status', isEqualTo: 'requested')
            .get();

        if (pendingAppts.docs.isNotEmpty) {
          final apptBatch = _db.batch();
          for (final apptDoc in pendingAppts.docs) {
            apptBatch.update(apptDoc.reference, {
              'handledBy': 'doctor',
              'operatorUid': FieldValue.delete(),
              'updatedAt': FieldValue.serverTimestamp(),
            });
          }
          await apptBatch.commit();
        }
      }
    } catch (_) {}
  }

  static Future<Map<String, dynamic>?> syncUser({
    required String uid,
    String? email,
    String? name,
    String? phone,
    String? role,
    bool isDoctor = false,
    String? photoUrl,
  }) async {
    try {
      final userRef = _db.collection('users').doc(uid);
      final existing = await userRef.get();

      if (!existing.exists) {
        final generatedUsername = await generateUniqueUsername(name, email);
        final userData = <String, dynamic>{
          'uid': uid,
          'email': email ?? '',
          'name': name ?? '',
          'username': generatedUsername,
          'photoUrl': photoUrl ?? '',
          'phone': phone ?? '',

          'roles': {
            'isDoctor': false,
            'isOperator': false,
            'isAdmin': false,
          },
          'chamberCount': 0,
          'doctorProfileId': null,
          'operatorAssignments': [],
          'createdAt': FieldValue.serverTimestamp(),
        };

        // Normal signups applying for doctor get pending status, never client-granted role
        if (isDoctor) {
          userData['doctorApplication'] = {
            'status': 'pending',
            'appliedAt': FieldValue.serverTimestamp(),
            'phone': phone ?? '',

            'name': name ?? '',
            'email': email ?? '',
          };
        }

        await userRef.set(userData);
        return userData;
      } else {
        final updates = <String, dynamic>{};
        final currentUsername = existing.data()?['username']?.toString() ?? '';
        if (currentUsername.isEmpty) {
          updates['username'] = await generateUniqueUsername(
            existing.data()?['name'] ?? name,
            existing.data()?['email'] ?? email,
          );
        }
        if (name != null &&
            name.isNotEmpty &&
            (existing.data()?['name'] == null ||
                existing.data()?['name'] == '')) {
          updates['name'] = name;
        }
        if (email != null &&
            email.isNotEmpty &&
            (existing.data()?['email'] == null ||
                existing.data()?['email'] == '')) {
          updates['email'] = email;
        }
        if (phone != null &&
            phone.isNotEmpty &&
            (existing.data()?['phone'] == null ||
                existing.data()?['phone'] == '')) {
          updates['phone'] = phone;
        }
        if (isDoctor) {
          final isAlreadyDoctor =
              existing.data()?['roles']?['isDoctor'] == true;
          if (!isAlreadyDoctor) {
            updates['doctorApplication'] = {
              'status': 'pending',
              'appliedAt': FieldValue.serverTimestamp(),
              'phone': phone ?? existing.data()?['phone'] ?? '',
              'name': name ?? existing.data()?['name'] ?? '',
              'email': email ?? existing.data()?['email'] ?? '',
            };
          }
        }
        if (photoUrl != null && photoUrl.isNotEmpty && existing.data()?['photoUrl'] != photoUrl) {
          updates['photoUrl'] = photoUrl;
        }
        updates['lastLoginAt'] = FieldValue.serverTimestamp();
        updates['updatedAt'] = FieldValue.serverTimestamp();
        if (updates.isNotEmpty) {
          await userRef.update(updates);
        }
        final merged = Map<String, dynamic>.from(existing.data() ?? {});
        merged.addAll(updates);
        return merged;
      }
    } catch (e) {
      debugPrint('Firestore syncUser error: $e');
      return null;
    }
  }

  /// Generates a unique username: firstname + unique 3-digit number (e.g. nuzhat719, rehnuma342)
  static Future<String> generateUniqueUsername(String? rawName, String? email) async {
    String base = '';
    if (rawName != null && rawName.trim().isNotEmpty) {
      base = rawName.trim().split(' ').first;
    } else if (email != null && email.isNotEmpty) {
      base = email.split('@').first.split('.').first;
    }
    base = base.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toLowerCase();
    if (base.isEmpty) base = 'user';
    if (base.length > 15) base = base.substring(0, 15);

    final random = Random();
    for (int attempt = 0; attempt < 10; attempt++) {
      final num = 100 + random.nextInt(900);
      final candidate = '$base$num';
      try {
        final existing = await _db
            .collection('users')
            .where('username', isEqualTo: candidate)
            .limit(1)
            .get();
        if (existing.docs.isEmpty) {
          return candidate;
        }
      } catch (_) {
        return candidate;
      }
    }
    return '$base${DateTime.now().millisecondsSinceEpoch % 10000}';
  }

  /// Checks if a username is available in database and updates it for [uid]
  static Future<Map<String, dynamic>> updateUsername({
    required String uid,
    required String newUsername,
  }) async {
    final clean = newUsername.trim().toLowerCase().replaceAll('@', '');
    if (clean.length < 3) {
      return {'success': false, 'error': 'Username must be at least 3 characters long.'};
    }
    if (!RegExp(r'^[a-z0-9_.]+$').hasMatch(clean)) {
      return {'success': false, 'error': 'Username can only contain letters, numbers, underscores, and dots.'};
    }

    try {
      final snap = await _db
          .collection('users')
          .where('username', isEqualTo: clean)
          .limit(1)
          .get();

      if (snap.docs.isNotEmpty && snap.docs.first.id != uid) {
        return {'success': false, 'error': 'Username @$clean is already taken. Please choose another.'};
      }

      await _db.collection('users').doc(uid).set({'username': clean}, SetOptions(merge: true));
      return {'success': true, 'username': clean};
    } catch (e) {
      return {'success': false, 'error': 'Database error checking username: $e'};
    }
  }

  /// Searches registered users by @username or name for 1-tap operator assignment
  static Future<List<Map<String, dynamic>>> searchUsersByUsername(String query) async {
    final clean = query.trim().toLowerCase().replaceAll('@', '');
    if (clean.isEmpty) return [];

    try {
      final snap = await _db
          .collection('users')
          .where('username', isGreaterThanOrEqualTo: clean)
          .where('username', isLessThanOrEqualTo: '$clean\uf8ff')
          .limit(15)
          .get();

      if (snap.docs.isNotEmpty) {
        return snap.docs.map((d) => {'uid': d.id, ...d.data()}).toList();
      }

      final allRecent = await fetchRegisteredUsers(limit: 30);
      return allRecent.where((u) {
        final uName = (u['username'] ?? '').toString().toLowerCase();
        final name = (u['name'] ?? '').toString().toLowerCase();
        final email = (u['email'] ?? '').toString().toLowerCase();
        return uName.contains(clean) || name.contains(clean) || email.contains(clean);
      }).toList();
    } catch (e) {
      debugPrint('searchUsersByUsername error: $e');
      return [];
    }
  }

  /// Fetches chambers directory across doctors for desk discovery & operator application
  static Future<List<Map<String, dynamic>>> fetchChambersDirectory({String? areaFilter}) async {
    final List<Map<String, dynamic>> result = [];
    final seen = <String>{};

    // 1. Fetch canonical chambers directly from chambers collection
    try {
      final chambersSnap = await _db.collection('chambers').limit(100).get();
      for (final doc in chambersSnap.docs) {
        final c = doc.data();
        if (c['hidden'] == true || c['isHidden'] == true) continue;
        final chId = doc.id;
        final chName = (c['name'] ?? c['hospitalName'] ?? c['chamberName'] ?? 'Chamber').toString();
        final docId = (c['ownerDoctorId'] ?? c['doctorId'] ?? '').toString();
        final docName = (c['doctorName'] ?? 'Doctor Specialist').toString();

        String hoursStr = '5:00 PM – 9:00 PM';
        final vh = c['visitingHours'];
        if (vh is Map && vh['display'] != null) {
          hoursStr = vh['display'].toString();
        } else if (vh is String && vh.trim().isNotEmpty) {
          hoursStr = vh.trim();
        } else if (c['visitingHoursDisplay'] is String && (c['visitingHoursDisplay'] as String).isNotEmpty) {
          hoursStr = c['visitingHoursDisplay'].toString();
        }

        if (seen.add(chId)) {
          result.add({
            'id': chId,
            'name': chName,
            'area': (c['area'] ?? c['location'] ?? 'Dhaka').toString(),
            'visitingHours': hoursStr,
            'fee': c['fee'] ?? 800,
            'doctorId': docId,
            'doctorName': docName,
            'doctorSpecialty': (c['doctorSpecialty'] ?? 'General Medicine').toString(),
            'hasOperator': c['hasOperator'] == true || c['operatorUid'] != null,
            'operatorUid': c['operatorUid'],
            'operatorName': c['operatorName'],
            'operatorEmail': c['operatorEmail'],
            'isAccessible': c['isAccessible'] == true || c['wheelchairEntrance'] == true,
            'isClaimedDoctor': true,
          });
        }
      }
    } catch (e) {
      debugPrint('Error fetching top-level chambers: $e');
    }

    // 2. Supplement with claimed / dynamic doctors from Firestore
    try {
      final firestoreDocs = await _db.collection('doctors').limit(50).get();
      for (final doc in firestoreDocs.docs) {
        final data = doc.data();
        final docId = doc.id;
        final docName = data['name'] ?? 'Doctor Specialist';
        final specs = (data['specialities'] as List?)?.join(', ') ?? 'General Medicine';
        final rawChambers = (data['chambers'] as List?) ?? [];
        for (final ch in rawChambers) {
          final c = Map<String, dynamic>.from(ch as Map);
          final chId = c['id']?.toString() ?? '${docId}_${c['name']}';
          if (seen.add(chId)) {
            result.add({
              'id': chId,
              'name': c['name'] ?? c['hospitalName'] ?? 'Chamber',
              'area': c['area'] ?? 'Dhaka',
              'visitingHours': c['visitingHours'] ?? '5:00 PM – 9:00 PM',
              'fee': c['fee'] ?? 800,
              'doctorId': docId,
              'doctorName': docName,
              'doctorSpecialty': specs,
              'hasOperator': c['hasOperator'] == true,
              'operatorUid': c['operatorUid'],
              'operatorName': c['operatorName'],
              'operatorEmail': c['operatorEmail'],
              'isAccessible': c['isAccessible'] == true,
              'isClaimedDoctor': true,
            });
          }
        }
      }
    } catch (e) {
      debugPrint('Error fetching firestore chambers: $e');
    }

    // 2. Supplement with bundled doctors chambers for comprehensive discovery
    try {
      final bundled = await getBundledDoctors();
      for (final doc in bundled.take(60)) {
        for (final ch in doc.chambers) {
          final chId = ch.id ?? '${doc.id}_${ch.hospitalName}';
          if (seen.add(chId)) {
            result.add({
              'id': chId,
              'name': ch.hospitalName ?? 'Clinic Chamber',
              'area': ch.area ?? ch.location ?? 'Dhaka',
              'visitingHours': ch.visitingHours ?? '5:00 PM – 9:00 PM',
              'fee': ch.fee ?? 800,
              'doctorId': doc.id,
              'doctorName': doc.name,
              'doctorSpecialty': doc.specialities.join(', '),
              'hasOperator': ch.hasOperator,
              'operatorUid': ch.operatorUid,
              'operatorName': ch.operatorName,
              'operatorEmail': ch.operatorEmail,
              'isAccessible': ch.isAccessible,
              'isClaimedDoctor': doc.isClaimed,
            });
          }
        }
      }
    } catch (e) {
      debugPrint('Error supplementing bundled chambers: $e');
    }

    if (areaFilter != null && areaFilter.trim().isNotEmpty && areaFilter != 'All') {
      final norm = areaFilter.trim().toLowerCase();
      return result.where((c) {
        final a = (c['area'] ?? '').toString().toLowerCase();
        final n = (c['name'] ?? '').toString().toLowerCase();
        return a.contains(norm) || n.contains(norm);
      }).toList();
    }

    return result;
  }

  /// Patient/User applies to be a Desk Operator for a specific chamber
  static Future<void> applyForDeskOperator({
    required String chamberId,
    required String chamberName,
    required String doctorId,
    required String doctorName,
    String? note,
    String? phone,
  }) async {
    final user = _auth.currentUser;
    if (user == null) throw StateError('Must be logged in to apply as desk operator.');

    final userProfile = await fetchUserProfile(user.uid);
    final applicantName = userProfile?['name'] ?? user.displayName ?? 'Applicant';
    final applicantUsername = userProfile?['username'] ?? user.email?.split('@').first ?? 'user';
    final applicantEmail = user.email ?? '';
    final applicantPhone = phone ?? userProfile?['phone'] ?? '';

    await _db.collection('operator_applications').add({
      'applicantUid': user.uid,
      'applicantName': applicantName,
      'applicantUsername': applicantUsername,
      'applicantEmail': applicantEmail,
      'applicantPhone': applicantPhone,
      'chamberId': chamberId,
      'chamberName': chamberName,
      'doctorId': doctorId,
      'doctorName': doctorName,
      'note': note ?? '',
      'status': 'pending',
      'appliedAt': FieldValue.serverTimestamp(),
    });

    try {
      await NotificationService.createNotification(
        userId: doctorId,
        title: 'New Operator Application',
        body: '$applicantName (@$applicantUsername) applied as Desk Operator for $chamberName.',
        type: 'system',
        relatedId: chamberId,
      );
    } catch (_) {}
  }

  /// Doctor streams operator applications for their chambers
  static Stream<QuerySnapshot<Map<String, dynamic>>> operatorApplicationsStream(String? doctorId) {
    final effectiveId = (doctorId != null && doctorId.trim().isNotEmpty)
        ? doctorId.trim()
        : AuthService.userRoles.doctorProfileId;
    if (effectiveId == null || effectiveId.isEmpty) {
      return const Stream.empty();
    }
    return _db
        .collection('operator_applications')
        .where('doctorId', isEqualTo: effectiveId)
        .snapshots();
  }

  /// Doctor agrees / approves the applicant as Desk Operator
  static Future<void> approveOperatorApplication({
    required String applicationId,
    required String doctorId,
    required String chamberId,
    required String applicantUid,
    required String applicantName,
    required String applicantEmail,
    required String chamberName,
  }) async {
    // 1. Assign operator in database (grants isOperator: true and binds chamber)
    await assignChamberOperator(
      doctorId: doctorId,
      chamberId: chamberId,
      operatorUid: applicantUid,
      operatorName: applicantName,
      operatorEmail: applicantEmail,
    );

    // 2. Mark application approved
    await _db.collection('operator_applications').doc(applicationId).update({
      'status': 'approved',
      'reviewedAt': FieldValue.serverTimestamp(),
    });

    // 3. Notify applicant that doctor agreed and approved them
    try {
      await NotificationService.createNotification(
        userId: applicantUid,
        title: 'Application Approved! 🎉',
        body: 'The doctor agreed to your application. You are now the Desk Operator for $chamberName.',
        type: 'system',
        relatedId: chamberId,
      );
    } catch (_) {}
  }

  /// Doctor rejects operator application
  static Future<void> rejectOperatorApplication(String applicationId) async {
    await _db.collection('operator_applications').doc(applicationId).update({
      'status': 'rejected',
      'reviewedAt': FieldValue.serverTimestamp(),
    });
  }

  /// Fetches pending doctor applications for admin review from the database
  static Future<List<Map<String, dynamic>>> fetchDoctorApplications() async {
    try {
      final snap = await _db
          .collection('users')
          .where('doctorApplication.status', whereIn: ['pending', 'under_appeal'])
          .get();
      return snap.docs.map((doc) => {'uid': doc.id, ...doc.data()}).toList();
    } catch (e) {
      debugPrint('Firestore fetchDoctorApplications error: $e');
      return [];
    }
  }

  /// Allocates or revokes the Doctor role in the database for a user (Admin only).
  /// If NID and BMDC are provided, verified badge/status can be allocated.
  static Future<void> setDoctorRole({
    required String uid,
    required bool isDoctor,
    bool isBmdcVerified = false,
    String? doctorProfileId,
    String? nid,
    String? bmdcNumber,
  }) async {
    final userRef = _db.collection('users').doc(uid);
    final updates = <String, dynamic>{
      'roles.isDoctor': isDoctor,
      'chamberCount': isDoctor ? 1 : 0,
      'doctorApplication.status': isDoctor ? 'approved' : 'revoked',
      'doctorApplication.reviewedAt': FieldValue.serverTimestamp(),
      'doctorApplication.reviewedByUid': _auth.currentUser?.uid,
      'isBmdcVerified': isBmdcVerified,
    };
    if (nid != null && nid.isNotEmpty) updates['nid'] = nid;
    if (bmdcNumber != null && bmdcNumber.isNotEmpty) {
      updates['bmdcRegNumber'] = bmdcNumber;
    }
    if (doctorProfileId != null) {
      updates['doctorProfileId'] = doctorProfileId;
    }
    await userRef.update(updates);
  }

  /// Approves a pending application by creating (or restoring) exactly one
  /// claimed directory profile and linking it to the applicant's user record.
  /// This operation is admin-authorized by Firestore rules; client UI alone
  /// can never grant the doctor role.
  static Future<String> approveDoctorApplication({
    required String uid,
  }) async {
    final userRef = _db.collection('users').doc(uid);
    final userSnapshot = await userRef.get();
    if (!userSnapshot.exists) {
      throw StateError('The applicant user record no longer exists.');
    }
    final user = userSnapshot.data()!;
    final application = Map<String, dynamic>.from(
      (user['doctorApplication'] as Map?) ?? const {},
    );
    final status = application['status']?.toString();
    if (status != 'pending' &&
        status != 'under_appeal' &&
        status != 'approved') {
      throw StateError('This user does not have a pending doctor application.');
    }

    final applicantName =
        (application['name']?.toString().trim().isNotEmpty == true
                ? application['name']
                : user['name'])
            ?.toString()
            .trim();
    if (applicantName == null || applicantName.isEmpty) {
      throw StateError('The application is missing the doctor name.');
    }
    final speciality = application['speciality']?.toString().trim();
    final bmdcNumber = application['bmdcNumber']?.toString().trim() ?? '';
    final existingClaim = await _db
        .collection('doctors')
        .where('claimedByUid', isEqualTo: uid)
        .limit(1)
        .get();
    final doctorRef = existingClaim.docs.isNotEmpty
        ? existingClaim.docs.first.reference
        : _db.collection('doctors').doc('doctor_$uid');
    final displayName =
        applicantName.startsWith('Dr.') ? applicantName : 'Dr. $applicantName';

    final batch = _db.batch();
    batch.set(
        doctorRef,
        {
          'name': displayName,
          'name_lower': displayName.toLowerCase(),
          'specialities': [
            speciality == null || speciality.isEmpty
                ? 'General Medicine'
                : speciality,
          ],
          'designation': 'Consultant',
          'education': const <String>[],
          'bmdcRegNumber': bmdcNumber,
          'bmdcNumber': bmdcNumber,
          'isClaimed': true,
          'claimStatus': 'claimed',
          'claimedByUid': uid,
          // Approval records an application review, not automatic BMDC verification.
          'isBmdcVerified': false,
          'verificationStatus': 'pending',
          'status': 'active',
          'phone': application['phone']?.toString() ??
              user['phone']?.toString() ??
              '',
          'createdAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
          ...DoctorSearchIndex.fieldsFor({
            'name': displayName,
            'designation': 'Consultant',
            'specialities': [
              speciality == null || speciality.isEmpty
                  ? 'General Medicine'
                  : speciality,
            ],
            'education': const <String>[],
          }),
        },
        SetOptions(merge: true));
    batch.set(
        userRef,
        {
          'roles': {
            ...Map<String, dynamic>.from((user['roles'] as Map?) ?? const {}),
            'isDoctor': true,
          },
          'chamberCount': 0,
          'doctorProfileId': doctorRef.id,
          'doctorApplication': {
            ...application,
            'status': 'approved',
            'reviewedAt': FieldValue.serverTimestamp(),
            'reviewedByUid': _auth.currentUser?.uid,
          },
          'isBmdcVerified': false,
        },
        SetOptions(merge: true));
    await batch.commit();
    invalidateClaimedDoctors();
    return doctorRef.id;
  }

  /// Submits an application for the doctor role to the database with optional NID and BMDC
  static Future<void> applyForDoctorRole({
    required String uid,
    required String phone,
    String? name,
    String? nid,
    String? bmdcNumber,
    String? speciality,
  }) async {
    final userRef = _db.collection('users').doc(uid);
    final hasDocs = (nid != null && nid.isNotEmpty) ||
        (bmdcNumber != null && bmdcNumber.isNotEmpty);
    await userRef.set({
      'phone': phone,
      'doctorApplication': {
        'status': 'pending',
        'appliedAt': FieldValue.serverTimestamp(),
        'phone': phone,
        'name': name ?? '',
        'nid': nid ?? '',
        'bmdcNumber': bmdcNumber ?? '',
        'speciality': speciality ?? '',
        'hasProvidedVerificationDocs': hasDocs,
      },
    }, SetOptions(merge: true));
  }

  /// Sets or revokes moderator role. Only Admins can execute this.
  static Future<void> setModeratorRole({
    required String uid,
    required bool isModerator,
  }) async {
    final userRef = _db.collection('users').doc(uid);
    await userRef.update({
      'roles.isModerator': isModerator,
      'moderatorUpdatedBy': _auth.currentUser?.uid,
      'moderatorUpdatedAt': FieldValue.serverTimestamp(),
    });
  }

  /// Fetches users with moderator role
  static Future<List<Map<String, dynamic>>> fetchModerators() async {
    try {
      final snap = await _db
          .collection('users')
          .where('roles.isModerator', isEqualTo: true)
          .get();
      return snap.docs.map((doc) => {'uid': doc.id, ...doc.data()}).toList();
    } catch (e) {
      debugPrint('Firestore fetchModerators error: $e');
      return [];
    }
  }

  // =========================================================================
  // REAL-TIME FEED & VIDEO POSTS
  // =========================================================================

  /// Stream of feed posts ordered by newest first
  static Stream<QuerySnapshot<Map<String, dynamic>>> feedPostsStream(
      {String? typeFilter}) {
    Query<Map<String, dynamic>> query =
        _db.collection('posts').orderBy('timestamp', descending: true);
    if (typeFilter != null && typeFilter != 'All') {
      query = query.where('type', isEqualTo: typeFilter);
    }
    return query.snapshots();
  }

  /// Creates a post in the feed.
  /// Doctors, Admins, and Moderators can post videos and tips.
  /// Patients and Operators can ask questions.
  static Future<String> createFeedPost({
    required String type, // 'video' | 'tip' | 'question'
    required String title,
    String? content,
    String? youtubeUrl,
    String? imageUrl,
    String? authorName,
    String? authorRole,
    bool isBmdcVerified = false,
  }) async {
    final user = _auth.currentUser;
    final uid = user?.uid ?? 'anonymous_user';
    final name = authorName ?? user?.displayName ?? 'Community Member';
    final role = authorRole ?? 'patient';

    final docRef = await _db.collection('posts').add({
      'type': type,
      'title': title,
      'content': content ?? '',
      'youtubeUrl': youtubeUrl ?? '',
      if (imageUrl != null && imageUrl.isNotEmpty) 'imageUrl': imageUrl,
      'userId': uid,
      'authorName': name,
      'authorRole': role,
      'isBmdcVerified': isBmdcVerified,
      'timestamp': FieldValue.serverTimestamp(),
      'answer': null,
      'likesCount': 0,
      'commentsCount': 0,
    });

    return docRef.id;
  }

  /// Answers a community question or FAQ.
  /// Allowed for Doctors, Admins, and Moderators.
  static Future<void> answerQuestion({
    required String postId,
    required String answerContent,
    String? doctorName,
    String? doctorRole,
  }) async {
    final name =
        doctorName ?? _auth.currentUser?.displayName ?? 'Dr. Specialist';
    final role = doctorRole ?? 'doctor';

    await _db.collection('posts').doc(postId).update({
      'answer': {
        'content': answerContent,
        'authorName': name,
        'authorRole': role,
        'authorUid': _auth.currentUser?.uid,
        'answeredAt': DateTime.now().toIso8601String(),
      },
    });
  }

  /// Adds a comment to a feed post.
  /// Allowed for all roles (patients, operators, doctors, admins).
  static Future<void> addPostComment({
    required String postId,
    required String comment,
    String? authorName,
    String? authorRole,
  }) async {
    final uid = _auth.currentUser?.uid ?? 'guest';
    final name =
        authorName ?? _auth.currentUser?.displayName ?? 'Community Member';
    final role = authorRole ?? 'patient';

    final postRef = _db.collection('posts').doc(postId);
    await postRef.collection('comments').add({
      'postId': postId,
      'userId': uid,
      'authorName': name,
      'authorRole': role,
      'comment': comment,
      'timestamp': FieldValue.serverTimestamp(),
    });

    try {
      await postRef.update({
        'commentsCount': FieldValue.increment(1),
      });
    } catch (_) {}

    // Trigger notification for the post author and commenter
    try {
      final postDoc = await postRef.get();
      if (postDoc.exists) {
        final postData = postDoc.data();
        final postAuthorUid = postData?['userId'] as String?;
        if (postAuthorUid != null && postAuthorUid.isNotEmpty && postAuthorUid != uid) {
          final preview = comment.length > 50 ? '${comment.substring(0, 50)}...' : comment;
          await NotificationService.createNotification(
            userId: postAuthorUid,
            title: 'New comment on your post',
            body: '$name commented: "$preview"',
            type: 'comment',
            relatedId: postId,
          );
        }
      }

      if (uid != 'guest') {
        await NotificationService.createNotification(
          userId: uid,
          title: 'Comment posted',
          body: 'Your comment was posted to the community feed.',
          type: 'comment',
          relatedId: postId,
        );
      }
    } catch (e) {
      debugPrint('Error triggering comment notification: $e');
    }
  }

  /// Stream of comments for a specific post
  static Stream<QuerySnapshot<Map<String, dynamic>>> postCommentsStream(
      String postId) {
    return _db
        .collection('posts')
        .doc(postId)
        .collection('comments')
        .orderBy('timestamp', descending: false)
        .snapshots();
  }

  /// Deletes a post (Author, Moderator, or Admin)
  static Future<void> deleteFeedPost(String postId) async {
    await _db.collection('posts').doc(postId).delete();
  }

  /// Retracts or deletes a doctor's answer/opinion on a post
  static Future<void> deleteDoctorAnswer(String postId) async {
    await _db.collection('posts').doc(postId).update({
      'answer': FieldValue.delete(),
    });
  }

  /// Deletes a comment on a feed post
  static Future<void> deletePostComment(String postId, String commentId) async {
    await _db
        .collection('posts')
        .doc(postId)
        .collection('comments')
        .doc(commentId)
        .delete();
    try {
      await _db.collection('posts').doc(postId).update({
        'commentsCount': FieldValue.increment(-1),
      });
    } catch (_) {}
  }

  // =========================================================================
  // SPECIALTY FEEDBACK (Analytics / accuracy loop)
  // =========================================================================

  static Future<void> submitSpecialtyFeedback({
    required String inputText,
    required String matchedSpecialty,
    required String source,
    required bool liked,
    String language = 'unknown',
  }) async {
    try {
      await _db.collection('specialty_feedback').add({
        'inputText': inputText,
        'matchedSpecialty': matchedSpecialty,
        'source': source,
        'liked': liked,
        'language': language,
        'userUid': _auth.currentUser?.uid,
      });
    } catch (_) {}
  }

  // =========================================================================
  // APPOINTMENTS & QUEUE MANAGEMENT
  // =========================================================================

  /// Fetches appointments for today (00:00 to 23:59) for a chamber or doctor.
  static Future<List<Map<String, dynamic>>> fetchTodayQueue(
      String chamberId) async {
    try {
      final uid = _auth.currentUser?.uid;
      if (uid == null) return [];
      final profile = await fetchUserProfile(uid);
      final roles = (profile?['roles'] as Map?)?.cast<String, dynamic>() ?? {};
      final doctorProfileId = profile?['doctorProfileId']?.toString();
      final assignments = (profile?['operatorAssignments'] as List?)
              ?.map((value) => value.toString())
              .toList() ??
          const <String>[];

      final now = DateTime.now();
      final startOfDay = DateTime(now.year, now.month, now.day, 0, 0, 0);
      final endOfDay = DateTime(now.year, now.month, now.day, 23, 59, 59, 999);

      Query<Map<String, dynamic>> query = _db.collection('appointments');
      if (roles['isDoctor'] == true &&
          doctorProfileId != null &&
          doctorProfileId.isNotEmpty) {
        query = query.where('doctorId', isEqualTo: doctorProfileId);
      } else if ((roles['isOperator'] == true && assignments.contains(chamberId)) || roles['isAdmin'] == true) {
        query = query.where('chamberId', isEqualTo: chamberId);
      } else {
        return [];
      }

      query = query
          .where('scheduledTime', isGreaterThanOrEqualTo: Timestamp.fromDate(startOfDay))
          .where('scheduledTime', isLessThanOrEqualTo: Timestamp.fromDate(endOfDay))
          .orderBy('scheduledTime', descending: false);

      final snapshot = await query.get();
      return snapshot.docs.map((doc) {
        final data = doc.data();
        data['_id'] = doc.id;
        data['id'] = doc.id;
        final st = data['scheduledTime'];
        if (st is Timestamp) {
          data['scheduledTime'] = st.toDate().toIso8601String();
        }
        return data;
      }).toList();
    } catch (e) {
      debugPrint('Firestore fetchTodayQueue error: $e');
      return [];
    }
  }

  /// Live stream of today's waiting count for a chamber (single source of truth).
  static Stream<int> streamTodayWaitingCount(String chamberId, {String? doctorId}) {
    final now = DateTime.now();
    final startOfDay = DateTime(now.year, now.month, now.day, 0, 0, 0);
    final endOfDay = DateTime(now.year, now.month, now.day, 23, 59, 59, 999);

    Query<Map<String, dynamic>> query =
        _db.collection('appointments').where('chamberId', isEqualTo: chamberId);
    if (doctorId != null && doctorId.isNotEmpty) {
      // Doctors may only read their own appointments; this filter lets the
      // rules allow the query (uses the chamber+doctor+status+time index).
      query = query
          .where('doctorId', isEqualTo: doctorId)
          .where('status', whereIn: ['requested', 'confirmed', 'in_progress']);
    }
    return query
        .where('scheduledTime', isGreaterThanOrEqualTo: Timestamp.fromDate(startOfDay))
        .where('scheduledTime', isLessThanOrEqualTo: Timestamp.fromDate(endOfDay))
        .snapshots()
        .map((snap) => snap.docs.where((doc) {
              final status = (doc.data()['status'] ?? '').toString().toLowerCase();
              return status != 'done' && status != 'cancelled';
            }).length);
  }

  /// Fetches unique doctor details practicing in a chamber matching id or name, hiding deleted/hidden doctors.
  static Future<List<Map<String, dynamic>>> fetchChamberDoctorDetails(
    String chamberId, {
    String? chamberName,
  }) async {
    try {
      final rec = await ChamberResolver.resolveChamberRecord(
        chamberId: chamberId,
        storedName: chamberName,
      );

      final List<Map<String, dynamic>> result = [];
      final Set<String> seenIds = {};

      if (rec != null && rec.doctorIds.isNotEmpty) {
        for (final docId in rec.doctorIds) {
          if (!seenIds.add(docId)) continue;
          final docSnap = await _db.collection('doctors').doc(docId).get();
          // Merged duplicates are hidden and must not show as extra doctors.
          if (docSnap.exists &&
              docSnap.data()?['hidden'] != true &&
              docSnap.data()?['isHidden'] != true) {
            final d = docSnap.data()!;
            final specialities = (d['specialities'] as List?) ?? [];
            result.add({
              'doctorId': docId,
              'name': (d['name'] ?? 'Doctor').toString(),
              'speciality': specialities.isNotEmpty ? specialities.first.toString() : 'Specialist',
              'hours': rec.visitingHours ?? '',
              'degree': (d['degree'] ?? '').toString(),
              'chamber': rec.raw,
            });
          }
        }
        if (result.isNotEmpty) return result;
      }

      final snap = await _db.collection('doctors').limit(100).get();

      for (final doc in snap.docs) {
        final d = doc.data();
        if (d['isDeleted'] == true ||
            d['isHidden'] == true ||
            d['status'] == 'deleted' ||
            d['status'] == 'hidden') {
          continue;
        }

        final chambers = (d['chambers'] as List?) ?? [];
        for (final c in chambers) {
          if (c is! Map) continue;
          final cId = (c['id'] ?? '').toString().trim();
          final cName = (c['name'] ?? '').toString().trim();
          final cHospital = (c['hospitalName'] ?? '').toString().trim();

          final matches = (cId.isNotEmpty && cId == chamberId) ||
              (cName.isNotEmpty && cName == chamberId) ||
              (cHospital.isNotEmpty && cHospital == chamberId) ||
              (chamberName != null &&
                  chamberName.isNotEmpty &&
                  (cName == chamberName ||
                      cHospital == chamberName ||
                      cId == chamberName));

          if (matches) {
            final docId = doc.id;
            if (seenIds.add(docId)) {
              final hours = (c['visitingHours'] ?? c['hours'] ?? c['time'] ?? '').toString();
              final specialities = (d['specialities'] as List?) ?? [];
              result.add({
                'doctorId': docId,
                'name': (d['name'] ?? 'Doctor').toString(),
                'speciality': specialities.isNotEmpty ? specialities.first.toString() : 'Specialist',
                'hours': hours,
                'degree': (d['degree'] ?? '').toString(),
                'chamber': c,
              });
            }
          }
        }
      }
      return result;
    } catch (_) {
      return [];
    }
  }

  /// Fetches unique doctor names practicing in a chamber.
  static Future<List<String>> fetchChamberDoctors(
    String chamberId, {
    String? chamberName,
  }) async {
    final details = await fetchChamberDoctorDetails(chamberId, chamberName: chamberName);
    return details.map((d) => (d['name'] ?? 'Doctor').toString()).toList();
  }

  static Future<Map<String, dynamic>> createAppointment({
    required String patientName,
    required DateTime scheduledTime,
    String? chamberId,
    String? chamberName,
    String? doctorId,
    String? doctorName,
    String? operatorNote,
    String status = 'waiting',
    DateTime? preferredTime,
  }) async {
    final uid = _auth.currentUser?.uid;
    if (uid == null || uid.isEmpty) {
      throw StateError('You must be signed in to book an appointment.');
    }

    final profile = await fetchUserProfile(uid);
    final roles = (profile?['roles'] as Map?)?.cast<String, dynamic>() ?? {};
    final resolvedDoctorId =
        (doctorId ?? profile?['doctorProfileId']?.toString())?.trim();
    final isDoctorQueueEntry = roles['isDoctor'] == true &&
        resolvedDoctorId != null &&
        resolvedDoctorId.isNotEmpty;
    final assignments = (profile?['operatorAssignments'] as List?)
            ?.map((value) => value.toString())
            .toList() ??
        const <String>[];
    final resolvedChamberId = (chamberId ?? '').trim();
    final isAssignedOperator = roles['isOperator'] == true &&
        resolvedChamberId.isNotEmpty &&
        assignments.contains(resolvedChamberId);

    if (!isDoctorQueueEntry && !isAssignedOperator) {
      if (resolvedDoctorId == null || resolvedDoctorId.isEmpty) {
        throw StateError('Please select a doctor to book an appointment.');
      }
    }

    final isPatient = !isDoctorQueueEntry && !isAssignedOperator && roles['isAdmin'] != true;
    final apptStatus = isPatient ? 'requested' : status;

    final bookingDay = DateTime(scheduledTime.year, scheduledTime.month, scheduledTime.day);
    if (bookingDay.isBefore(SchedulingService.today) ||
        bookingDay.isAfter(SchedulingService.lastBookableDate)) {
      throw StateError(
          'Appointments can be booked for today and the next ${SchedulingService.bookingWindowDays - 1} days.');
    }

    String resolvedChamberName = (chamberName ?? '').trim();

    // Look up canonical chamber record
    final chamberRec = await ChamberResolver.resolveChamberRecord(
      chamberId: resolvedChamberId,
      doctorId: resolvedDoctorId,
      storedName: chamberName,
    );
    final canonicalChamberId = chamberRec?.id ?? resolvedChamberId;
    if (resolvedChamberName.isEmpty) {
      resolvedChamberName = chamberRec?.name ?? 'Chamber';
    }

    // Routing uses chamber_operators for that doctor first, else the doctor
    final List<String> operatorUids = [];
    if (canonicalChamberId.isNotEmpty && resolvedDoctorId != null && resolvedDoctorId.isNotEmpty) {
      try {
        final opDoc = await _db
            .collection('chamber_operators')
            .where('chamberId', isEqualTo: canonicalChamberId)
            .where('doctorId', isEqualTo: resolvedDoctorId)
            .get();
        for (final doc in opDoc.docs) {
          final opUid = (doc.data()['operatorUid'] ?? '').toString().trim();
          if (opUid.isNotEmpty && !operatorUids.contains(opUid)) {
            operatorUids.add(opUid);
          }
        }
      } catch (_) {}
    }

    final bool hasOperator = operatorUids.isNotEmpty;
    final String handledBy = hasOperator ? 'operator' : 'doctor';

    final dateKey = '${scheduledTime.year}-${scheduledTime.month.toString().padLeft(2, "0")}-${scheduledTime.day.toString().padLeft(2, "0")}';
    final activeBookingKey = '${uid}_${resolvedDoctorId ?? "doc"}_${resolvedChamberId}_$dateKey';
    final activeBookingRef = _db.collection('active_bookings').doc(activeBookingKey);
    final apptRef = _db.collection('appointments').doc();

    if (isPatient) {
      // Reject if this patient already has an active appointment with same doctor and chamber on same date.
      // The active_bookings lock doc uniquely identifies (userId_doctorId_chamberId_dateKey),
      // making a fast direct get() sufficient without needing a composite index on appointments.
      final overrideDocId = '${resolvedChamberId}_${SchedulingService.dateKey(scheduledTime)}';
      final overrideCheck = await _db.collection('chamber_day_overrides').doc(overrideDocId).get();
      if (overrideCheck.exists) {
        final st = (overrideCheck.data()?['status'] ?? '').toString().toLowerCase();
        if (st == 'closed') {
          throw StateError('This date is closed for appointments.');
        } else if (st == 'full') {
          throw StateError('This date is already fully booked.');
        }
      }
      // One open appointment per patient per doctor. Once it is done,
      // cancelled, rejected, declined or a no-show they may book again,
      // the same day included.
      final mine = await _db
          .collection('appointments')
          .where('userId', isEqualTo: uid)
          .where('doctorId', isEqualTo: resolvedDoctorId)
          .get();
      final open = mine.docs.where((d) =>
          !ApptStatus.terminal.contains(QueueService.normalizeStatus(d.data()['status'])));
      if (open.isNotEmpty) {
        throw StateError('You already have an open appointment with this doctor. '
            'You can book again once it is done or cancelled.');
      }
      // A lock left behind by a finished appointment must not block a new one.
      final activeCheck = await activeBookingRef.get();
      if (activeCheck.exists) {
        await activeBookingRef.delete();
      }

      await _db.runTransaction((tx) async {
        final activeSnap = await tx.get(activeBookingRef);
        if (activeSnap.exists) {
          throw StateError('You already have a request for this doctor on this date.');
        }

        final data = <String, dynamic>{
          'patientName': patientName,
          'doctorName': doctorName ?? 'Specialist Doctor',
          'scheduledTime': Timestamp.fromDate(scheduledTime),
          'chamberId': resolvedChamberId.isEmpty ? 'demo-chamber' : resolvedChamberId,
          if (resolvedChamberName.isNotEmpty) 'chamberName': resolvedChamberName,
          'doctorId': resolvedDoctorId,
          'operatorNote': operatorNote ?? '',
          'status': apptStatus,
          if (preferredTime != null) 'preferredTime': Timestamp.fromDate(preferredTime),
          'handledBy': handledBy,
          'activeBookingKey': activeBookingKey,
          'userId': uid,
          'createdAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        };

        tx.set(apptRef, data);
        tx.set(activeBookingRef, {
          'appointmentId': apptRef.id,
          'userId': uid,
          'doctorId': resolvedDoctorId,
          'chamberId': resolvedChamberId,
          'date': dateKey,
          'createdAt': FieldValue.serverTimestamp(),
        });
      });
    } else {
      final countSnap = await _db
          .collection('appointments')
          .where('chamberId', isEqualTo: resolvedChamberId)
          .count()
          .get();
      final queuePos = (countSnap.count ?? 0) + 1;

      final data = <String, dynamic>{
        'patientName': patientName,
        'doctorName': doctorName ?? 'Specialist Doctor',
        'scheduledTime': Timestamp.fromDate(scheduledTime),
        'chamberId': resolvedChamberId.isEmpty ? 'demo-chamber' : resolvedChamberId,
        if (resolvedChamberName.isNotEmpty) 'chamberName': resolvedChamberName,
        'doctorId': resolvedDoctorId,
        'operatorNote': operatorNote ?? '',
        'status': apptStatus,
        'handledBy': handledBy,
        'queuePosition': queuePos,
        'userId': uid,
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      };
      await apptRef.set(data);
    }

    try {
      final docLabel = doctorName ?? 'your doctor';
      // 1. Patient: "Appointment Requested"
      if (isPatient) {
        await NotificationService.createNotification(
          userId: uid,
          title: 'Appointment Requested',
          body: 'Your request with $docLabel for ${scheduledTime.day}/${scheduledTime.month}/${scheduledTime.year} has been submitted and is awaiting confirmation.',
          type: 'appointment_requested',
          relatedId: apptRef.id,
        );
      }

      // 2. Doctor and desk get it as an event in their staff chat.
      final prefers = preferredTime == null ? '' : ', prefers ${SchedulingService.eventTime(preferredTime).split(', ').last}';
      await ChatService.postAppointmentEvent(
        doctorId: resolvedDoctorId ?? '',
        appointmentId: apptRef.id,
        text: '📅 New request: $patientName · ${resolvedChamberName.isEmpty ? 'Chamber' : resolvedChamberName} · '
            '${SchedulingService.eventTime(scheduledTime).split(',').first}$prefers',
      );
    } catch (_) {}

    return {
      '_id': apptRef.id,
      'id': apptRef.id,
      'status': apptStatus,
      'scheduledTime': scheduledTime.toIso8601String(),
    };
  }

  static Future<void> updateAppointment(
      String id, Map<String, dynamic> updates) async {
    final cleanUpdates = Map<String, dynamic>.from(updates);
    if (cleanUpdates.containsKey('scheduledTime') &&
        cleanUpdates['scheduledTime'] is String) {
      final dt = DateTime.tryParse(cleanUpdates['scheduledTime']);
      if (dt != null) {
        cleanUpdates['scheduledTime'] = Timestamp.fromDate(dt);
      }
    }
    await _db.collection('appointments').doc(id).update(cleanUpdates);
  }

  static Future<void> updateQueueOrder(
      List<Map<String, dynamic>> updates) async {
    final batch = _db.batch();
    for (final u in updates) {
      final id = (u['id'] ?? u['_id']) as String?;
      final pos = u['queuePosition'] as int?;
      if (id != null && pos != null) {
        final ref = _db.collection('appointments').doc(id);
        batch.update(ref, {'queuePosition': pos});
      }
    }
    await batch.commit();
  }

  static Future<void> deleteAppointment(String id) async {
    await _db.collection('appointments').doc(id).delete();
  }

  static Future<void> clearAllAppointments() async {
    final snapshot = await _db.collection('appointments').get();
    final batch = _db.batch();
    for (final doc in snapshot.docs) {
      batch.delete(doc.reference);
    }
    await batch.commit();
  }

  /// Stream or fetch claim requests for admin console
  static Stream<List<Map<String, dynamic>>> streamClaimRequests({String? statusFilter}) {
    Query<Map<String, dynamic>> query = _db.collection('claim_requests');
    if (statusFilter != null && statusFilter != 'all') {
      query = query.where('status', isEqualTo: statusFilter);
    }
    return query.snapshots().map(
      (snap) {
        // Rejected claims leave the console 24 h after review; the record
        // stays in Firestore.
        final cutoff = DateTime.now().subtract(const Duration(hours: 24));
        final list = snap.docs.map((d) {
          final data = Map<String, dynamic>.from(d.data());
          data['id'] = d.id;
          return data;
        }).where((c) {
          if (c['status'] != 'rejected') return true;
          final at = (c['reviewedAt'] as Timestamp?)?.toDate();
          return at == null || at.isAfter(cutoff);
        }).toList();
        list.sort((a, b) {
          final aTime = a['submittedAt'] as Timestamp?;
          final bTime = b['submittedAt'] as Timestamp?;
          if (aTime == null || bTime == null) return 0;
          return bTime.compareTo(aTime);
        });
        return list;
      },
    );
  }

  /// Admin approves a doctor claim request
  static Future<void> approveClaimRequest({
    required String requestId,
    required String doctorId,
    required String applicantUid,
    required String bmdcNumber,
    required String adminUid,
  }) async {
    String? docName;
    final doctorRef = _db.collection('doctors').doc(doctorId);
    final claimRef = _db.collection('claim_requests').doc(requestId);
    try {
      final docSnap = await doctorRef.get();
      if (docSnap.exists) {
        docName = docSnap.data()?['name']?.toString();
      }
      if (docName == null || docName.isEmpty) {
        final claimSnap = await claimRef.get();
        if (claimSnap.exists) {
          docName = claimSnap.data()?['doctorName']?.toString();
        }
      }
    } catch (_) {}

    // Someone else may have claimed it since the request was made.
    final current = (await doctorRef.get()).data()?['claimedByUid']?.toString() ?? '';
    if (current.isNotEmpty && current != applicantUid) {
      throw StateError('This profile is already claimed by another account.');
    }

    final batch = _db.batch();
    batch.update(claimRef, {
      'status': 'approved',
      'reviewedAt': FieldValue.serverTimestamp(),
      'reviewedBy': adminUid,
    });

    batch.set(doctorRef, {
      if (docName != null && docName.isNotEmpty) 'name': docName,
      if (docName != null && docName.isNotEmpty) 'name_lower': docName.toLowerCase(),
      'claimedByUid': applicantUid,
      'isClaimed': true,
      'claimStatus': 'approved',
      'bmdcNumber': bmdcNumber,
      'bmdcRegNumber': bmdcNumber,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    final userRef = _db.collection('users').doc(applicantUid);
    batch.set(userRef, {
      'roles': {
        'isDoctor': true,
      },
      'doctorProfileId': doctorId,
      'bmdcRegNumber': bmdcNumber,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    await batch.commit();
    invalidateClaimedDoctors();

    try {
      await NotificationService.createNotification(
        userId: applicantUid,
        title: 'Doctor Profile Claim Approved! 🎉',
        body: 'Your claim request has been verified and approved by the admin.',
        type: 'claim_approved',
        relatedId: doctorId,
      );
    } catch (_) {}
  }

  /// Admin rejects a doctor claim request
  static Future<void> rejectClaimRequest({
    required String requestId,
    required String doctorId,
    required String applicantUid,
    required String reason,
    required String adminUid,
  }) async {
    final batch = _db.batch();
    final claimRef = _db.collection('claim_requests').doc(requestId);
    batch.update(claimRef, {
      'status': 'rejected',
      'rejectionReason': reason,
      'reviewedAt': FieldValue.serverTimestamp(),
      'reviewedBy': adminUid,
    });

    final doctorRef = _db.collection('doctors').doc(doctorId);
    batch.set(doctorRef, {
      'claimStatus': 'unclaimed',
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    await batch.commit();

    try {
      await NotificationService.createNotification(
        userId: applicantUid,
        title: 'Doctor Profile Claim Rejected',
        body: 'Reason: ',
        type: 'claim_rejected',
        relatedId: doctorId,
      );
    } catch (_) {}
  }

  /// Stores a manual BMDC decision and an immutable audit entry in one batch.
  /// Firestore rules require the caller to be represented by /admins/{uid}.
  static Future<void> recordManualBmdcVerification({
    required String doctorId,
    required String registrationNumber,
    required String outcome,
    String? note,
  }) async {
    const allowedOutcomes = {'found', 'not_found', 'mismatch'};
    if (!allowedOutcomes.contains(outcome)) {
      throw ArgumentError.value(outcome, 'outcome', 'Unsupported BMDC outcome');
    }
    final adminUid = _auth.currentUser?.uid;
    if (adminUid == null || adminUid.isEmpty) {
      throw StateError('An authenticated admin is required for BMDC verification.');
    }
    final doctorRef = _db.collection('doctors').doc(doctorId);
    final historyRef = _db.collection('doctor_verification_history').doc();
    final isFound = outcome == 'found';
    final verificationStatus = outcome == 'found'
        ? 'checked_found'
        : (outcome == 'mismatch' ? 'checked_mismatch' : 'checked_not_found');

    final batch = _db.batch();
    batch.set(doctorRef, {
      'bmdcNumber': registrationNumber.trim(),
      'bmdcRegNumber': registrationNumber.trim(),
      'verificationStatus': verificationStatus,
      'isBmdcVerified': isFound,
      'checkedAt': FieldValue.serverTimestamp(),
      'checkedBy': adminUid,
      'sourceUrl': 'https://verify.bmdc.org.bd/',
      'method': 'manual',
      'note': note?.trim() ?? '',
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    batch.set(historyRef, {
      'doctorId': doctorId,
      'bmdcNumber': registrationNumber.trim(),
      'outcome': outcome,
      'provider': 'manual',
      'method': 'manual',
      'sourceUrl': 'https://verify.bmdc.org.bd/',
      'note': note?.trim() ?? '',
      'verifiedByUid': adminUid,
      'checkedBy': adminUid,
      'checkedAt': FieldValue.serverTimestamp(),
      'verifiedAt': FieldValue.serverTimestamp(),
    });

    final doctor = await doctorRef.get();
    final claimedUid = doctor.data()?['claimedByUid']?.toString();
    if (claimedUid != null && claimedUid.isNotEmpty) {
      final userRef = _db.collection('users').doc(claimedUid);
      batch.set(userRef, {
        'isBmdcVerified': isFound,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    }

    await batch.commit();
  }

  /// Fetches doctors from Firestore for verification review
  static Future<List<Map<String, dynamic>>> fetchDoctorsForVerification({
    String? statusFilter,
  }) async {
    Query<Map<String, dynamic>> query = _db.collection('doctors');
    if (statusFilter != null && statusFilter != 'all') {
      query = query.where('verificationStatus', isEqualTo: statusFilter);
    }
    final snap = await query.limit(100).get();
    return snap.docs.map((d) {
      final data = Map<String, dynamic>.from(d.data());
      data['id'] = d.id;
      return data;
    }).toList();
  }

  static List<Doctor>? _cachedBundledDoctors;

  /// Loads the full 6,000+ doctors bundled in local APK assets (0 Firestore reads)
  static Future<List<Doctor>> getBundledDoctors() async {
    if (_cachedBundledDoctors != null && _cachedBundledDoctors!.isNotEmpty) {
      return _cachedBundledDoctors!;
    }
    try {
      final jsonStr = await rootBundle.loadString('assets/data/bundled_doctors.json');
      _cachedBundledDoctors = await compute(_parseBundledDoctorsJson, jsonStr);
      return _cachedBundledDoctors!;
    } catch (e) {
      debugPrint('Error loading bundled doctors: $e');
      final fallbackSeed = _defaultFallbackDoctors();
      _cachedBundledDoctors = fallbackSeed.map((j) => Doctor.fromJson(j)).toList();
      return _cachedBundledDoctors!;
    }
  }

  /// Returns the actual number of records in the APK's bundled directory.
  /// Admin upload UI uses this instead of a hand-maintained display constant.
  static List<Doctor> _parseBundledDoctorsJson(String jsonStr) {
    final List decoded = jsonDecode(jsonStr);
    return decoded.map((j) => Doctor.fromJson(j as Map<String, dynamic>)).toList();
  }

  static Future<int> bundledDoctorCount() async => (await getBundledDoctors()).length;

  static List<Map<String, dynamic>> _defaultFallbackDoctors() {
    return [
      {
        '_id': 'doc_fallback_1',
        'name': 'Dr. Nuzhat Saima',
        'designation': 'Specialist Consultant',
        'specialities': ['General Medicine'],
        'education': ['MBBS', 'FCPS'],
        'bmdcRegNumber': 'A-98765',
        'isBmdcVerified': true,
        'ratingAverage': 0.0,
        'ratingCount': 0,
        'chambers': [
          {
            'hospitalName': 'Bup Medical',
            'area': 'Mirpur',
            'location': 'Dhaka',
            'lat': 23.8398,
            'lng': 90.3582,
          }
        ],
      },
      {
        '_id': 'doc_fallback_2',
        'name': 'Dr. Md. Kamrul Islam',
        'designation': 'Professor & Head',
        'specialities': ['General Surgery', 'Urology'],
        'education': ['MBBS', 'FCPS', 'FRCS'],
        'bmdcRegNumber': 'A-12345',
        'isBmdcVerified': true,
        'ratingAverage': 0.0,
        'ratingCount': 0,
        'chambers': [
          {
            'hospitalName': 'Dhaka Medical College Hospital',
            'area': 'Bakshibazar',
            'location': 'Dhaka',
            'lat': 23.7258,
            'lng': 90.3976,
          }
        ],
      },
      {
        '_id': 'doc_fallback_3',
        'name': 'Dr. Farzana Rahman',
        'designation': 'Associate Professor',
        'specialities': ['General Medicine', 'Internal Medicine'],
        'education': ['MBBS', 'FCPS', 'MRCP'],
        'bmdcRegNumber': 'A-23456',
        'isBmdcVerified': true,
        'ratingAverage': 0.0,
        'ratingCount': 0,
        'chambers': [
          {
            'hospitalName': 'Square Hospital',
            'area': 'Panthapath',
            'location': 'Dhaka',
            'lat': 23.7533,
            'lng': 90.3817,
          }
        ],
      },
      {
        '_id': 'doc_fallback_4',
        'name': 'Dr. Alim Chowdhury',
        'designation': 'Senior Consultant',
        'specialities': ['Otolaryngology', 'ENT Specialist'],
        'education': ['MBBS', 'DLO', 'FCPS'],
        'bmdcRegNumber': 'A-34567',
        'isBmdcVerified': true,
        'ratingAverage': 0.0,
        'ratingCount': 0,
        'chambers': [
          {
            'hospitalName': 'Green Life Hospital',
            'area': 'Green Road',
            'location': 'Dhaka',
            'lat': 23.7483,
            'lng': 90.3861,
          }
        ],
      },
      {
        '_id': 'doc_fallback_5',
        'name': 'Dr. Selina Banu',
        'designation': 'Professor & Consultant',
        'specialities': ['Gynecology and Obstetrics'],
        'education': ['MBBS', 'FCPS', 'MS (Gynae)'],
        'bmdcRegNumber': 'A-45678',
        'isBmdcVerified': true,
        'ratingAverage': 0.0,
        'ratingCount': 0,
        'chambers': [
          {
            'hospitalName': 'Popular Diagnostic Centre',
            'area': 'Dhanmondi',
            'location': 'Dhaka',
            'lat': 23.7392,
            'lng': 90.3824,
          }
        ],
      },
      {
        '_id': 'doc_fallback_6',
        'name': 'Dr. Kamal Hossain',
        'designation': 'Associate Professor',
        'specialities': ['Dermatology'],
        'education': ['MBBS', 'DDV', 'FCPS'],
        'bmdcRegNumber': 'A-56789',
        'isBmdcVerified': true,
        'ratingAverage': 0.0,
        'ratingCount': 0,
        'chambers': [
          {
            'hospitalName': 'Labaid Specialized Hospital',
            'area': 'Dhanmondi',
            'location': 'Dhaka',
            'lat': 23.7465,
            'lng': 90.3760,
          }
        ],
      },
      {
        '_id': 'doc_fallback_kallyanpur',
        'name': 'Dr. Md. Atikur Rahman',
        'designation': 'Consultant Physician',
        'specialities': ['General Medicine', 'Internal Medicine'],
        'education': ['MBBS', 'FCPS'],
        'bmdcRegNumber': 'A-67890',
        'isBmdcVerified': true,
        'ratingAverage': 0.0,
        'ratingCount': 0,
        'chambers': [
          {
            'hospitalName': 'Ibn Sina Medical College Hospital',
            'area': 'Kallyanpur',
            'location': 'Dhaka',
            'lat': 23.7782,
            'lng': 90.3621,
          }
        ],
      },
      {
        '_id': 'doc_fallback_7',
        'name': 'Dr. Jahangir Kabir',
        'designation': 'Chief Cardiac Surgeon',
        'specialities': ['Cardiology'],
        'education': ['MBBS', 'MS (CTS)', 'FACS'],
        'bmdcRegNumber': 'A-67890',
        'isBmdcVerified': true,
        'ratingAverage': 0.0,
        'ratingCount': 0,
        'chambers': [
          {
            'hospitalName': 'National Heart Foundation',
            'area': 'Mirpur',
            'location': 'Dhaka',
          }
        ],
      },
    ];
  }

  /// Uploads bundled doctors to Firestore in batches of 500.
  /// Uses stable IDs from bundled JSON, is idempotent (set with merge: true),
  /// and is resumable via SharedPreferences cursor.
  static Future<void> uploadBundledDoctorsToFirestore({
    required Function(int processed, int total, String status) onProgress,
    bool restartFromBeginning = false,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    const cursorKey = 'admin_bundled_doctors_upload_cursor';
    int startIndex = restartFromBeginning ? 0 : (prefs.getInt(cursorKey) ?? 0);

    final jsonStr = await rootBundle.loadString('assets/data/bundled_doctors.json');
    final List decoded = jsonDecode(jsonStr);
    final total = decoded.length;

    if (startIndex >= total) {
      startIndex = 0;
    }

    const batchSize = 500;
    for (int i = startIndex; i < total; i += batchSize) {
      final end = (i + batchSize < total) ? (i + batchSize) : total;
      final chunk = decoded.sublist(i, end);

      final batch = _db.batch();
      for (int cIdx = 0; cIdx < chunk.length; cIdx++) {
        final item = Map<String, dynamic>.from(chunk[cIdx] as Map);
        final stableId = (item['_id'] ?? item['id'] ?? 'doc_${i + cIdx}').toString();
        final docRef = _db.collection('doctors').doc(stableId);

        final name = (item['name'] ?? '').toString();
        final specs = List<String>.from(item['specialities'] ?? []);
        final bmdc = (item['bmdcNumber'] ?? item['bmdcRegNumber'] ?? '').toString();
        final isVer = item['isBmdcVerified'] == true;
        final claimed = item['isClaimed'] == true || item['claimedByUid'] != null;

        final data = <String, dynamic>{
          'name': name,
          'name_lower': name.toLowerCase(),
          'specialities': specs,
          'designation': (item['designation'] ?? 'Consultant').toString(),
          'experienceYears': (item['experienceYears'] as num?)?.toDouble() ?? 5.0,
          'education': List<String>.from(item['education'] ?? ['MBBS']),
          'bmdcNumber': bmdc,
          'bmdcRegNumber': bmdc,
          'isBmdcVerified': isVer,
          'verificationStatus': isVer ? 'verified' : 'unverified',
          'isClaimed': claimed,
          'claimStatus': claimed ? 'claimed' : 'unclaimed',
          if (item['claimedByUid'] != null) 'claimedByUid': item['claimedByUid'].toString(),
          'ratingAverage': (item['ratingAverage'] as num?)?.toDouble() ?? 0.0,
          'ratingCount': (item['ratingCount'] as num?)?.toInt() ?? 0,
          'chambers': item['chambers'] ?? [],
          'status': 'active',
          'updatedAt': FieldValue.serverTimestamp(),
          ...DoctorSearchIndex.fieldsFor({
            'name': name,
            'designation': item['designation'] ?? 'Consultant',
            'specialities': specs,
            'education': item['education'] ?? ['MBBS'],
            'chambers': item['chambers'] ?? [],
          }),
        };

        batch.set(docRef, data, SetOptions(merge: true));
      }

      onProgress(i, total, 'Writing batch ${(i ~/ batchSize) + 1} of ${(total / batchSize).ceil()}...');
      await batch.commit();

      await prefs.setInt(cursorKey, end);
      onProgress(end, total, 'Uploaded $end / $total doctors');
    }

    onProgress(total, total, 'Upload complete! All $total doctors are live in Firestore.');
  }

  /// Links a doctor profile to an existing user by email.
  /// Looks up user by email; throws if user does not exist (no placeholders written).
  static Future<Map<String, dynamic>> assignDoctorToEmail({
    required String doctorId,
    required String email,
  }) async {
    final cleanEmail = email.trim().toLowerCase();
    final userSnap = await _db
        .collection('users')
        .where('email', isEqualTo: cleanEmail)
        .limit(1)
        .get();

    if (userSnap.docs.isEmpty) {
      throw StateError('No registered user found with email "$cleanEmail".');
    }

    final userDoc = userSnap.docs.first;
    final uid = userDoc.id;
    final userData = userDoc.data();
    final existingRoles = Map<String, dynamic>.from((userData['roles'] as Map?) ?? const {});
    existingRoles['isDoctor'] = true;

    final batch = _db.batch();

    final doctorRef = _db.collection('doctors').doc(doctorId);
    final docSnap = await doctorRef.get();
    final dData = docSnap.data() ?? {};
    final docName = (dData['name'] ?? userData['displayName'] ?? userData['name'] ?? 'Doctor Specialist').toString();
    final docNameLower = (dData['name_lower'] ?? docName.toLowerCase()).toString();

    batch.set(doctorRef, {
      'name': docName,
      'name_lower': docNameLower,
      'claimedByUid': uid,
      'isClaimed': true,
      'claimStatus': 'claimed',
      'status': 'active',
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    batch.set(userDoc.reference, {
      'roles': existingRoles,
      'doctorProfileId': doctorId,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    await batch.commit();

    return {
      'uid': uid,
      'email': cleanEmail,
      'name': userData['name'] ?? 'User',
      'doctorId': doctorId,
    };
  }

  /// If an operator is assigned or removed later, requests still 'requested' are re-routed:
  /// recompute handledBy from the current operators.
  static Future<void> reroutePendingRequests({
    List<String>? chamberIds,
    String? doctorId,
  }) async {
    try {
      final effectiveDoctorId = (doctorId != null && doctorId.trim().isNotEmpty)
          ? doctorId.trim()
          : AuthService.userRoles.doctorProfileId;

      if ((chamberIds == null || chamberIds.isEmpty) &&
          (effectiveDoctorId == null || effectiveDoctorId.isEmpty)) {
        return;
      }

      Query<Map<String, dynamic>> query = _db
          .collection('appointments')
          .where('status', isEqualTo: 'requested');

      if (chamberIds != null && chamberIds.isNotEmpty) {
        query = query.where('chamberId', whereIn: chamberIds);
        if (doctorId != null && doctorId.trim().isNotEmpty) {
          query = query.where('doctorId', isEqualTo: doctorId.trim());
        }
      } else if (effectiveDoctorId != null && effectiveDoctorId.isNotEmpty) {
        query = query.where('doctorId', isEqualTo: effectiveDoctorId);
      }

      final snap = await query.get();
      if (snap.docs.isEmpty) return;

      final batch = _db.batch();
      bool hasUpdates = false;
      final Map<String, bool> chamberHasOperators = {};

      for (final doc in snap.docs) {
        final data = doc.data();
        final chId = (data['chamberId'] ?? '').toString();
        if (chId.isEmpty) continue;

        if (!chamberHasOperators.containsKey(chId)) {
          final opUsers = await _db
              .collection('users')
              .where('operatorAssignments', arrayContains: chId)
              .limit(1)
              .get();
          chamberHasOperators[chId] = opUsers.docs.isNotEmpty;
        }

        final expectedHandledBy = chamberHasOperators[chId] == true ? 'operator' : 'doctor';
        if (data['handledBy'] != expectedHandledBy) {
          batch.update(doc.reference, {
            'handledBy': expectedHandledBy,
            'updatedAt': FieldValue.serverTimestamp(),
          });
          hasUpdates = true;
        }
      }

      if (hasUpdates) {
        await batch.commit();
      }
    } catch (_) {}
  }

  /// Returns available free time slots for a doctor on a given date using dynamic chamber visiting hours.
  static Future<List<DateTime>> getFreeSlotsForDoctor({
    required String doctorId,
    required DateTime date,
    String? chamberId,
    int slotMinutes = 10,
  }) async {
    final result = await SchedulingService.getFreeSlots(
      chamberId: chamberId ?? '',
      doctorId: doctorId,
      date: date,
      defaultSlotMinutes: slotMinutes,
    );
    return result.slots;
  }

  /// Checks whether an appointment time has conflicts via atomic doctor_slots lock document.
  static Future<void> checkAppointmentConflict({
    required String doctorId,
    required String chamberId,
    required DateTime proposedTime,
    String? excludeAppointmentId,
    int slotMinutes = 10,
  }) async {
    final sId = SchedulingService.slotId(doctorId, proposedTime);
    final slotSnap = await _db.collection('doctor_slots').doc(sId).get();
    if (slotSnap.exists) {
      final apptId = slotSnap.data()?['appointmentId']?.toString();
      if (apptId != null && apptId != excludeAppointmentId) {
        throw StateError('Schedule conflict: Doctor already has an appointment booked in this slot.');
      }
    }
  }

  /// Confirms an appointment, assigns time and queue number atomically using SchedulingService.
  static Future<void> confirmAppointment({
    required String appointmentId,
    required DateTime confirmedTime,
    int slotMinutes = 10,
  }) async {
    final actorUid = _auth.currentUser?.uid ?? 'system';
    await SchedulingService.acceptAppointment(
      appointmentId: appointmentId,
      slot: confirmedTime,
      actorUid: actorUid,
    );
  }

  /// Reschedules an appointment to a new time atomically using SchedulingService.
  static Future<void> rescheduleAppointment({
    required String appointmentId,
    required DateTime newTime,
    int slotMinutes = 10,
  }) async {
    final actorUid = _auth.currentUser?.uid ?? 'system';
    await SchedulingService.rescheduleAppointment(
      appointmentId: appointmentId,
      newSlot: newTime,
      actorUid: actorUid,
    );
  }

  /// Rejects an appointment with a reason and notifies the patient.
  static Future<void> rejectAppointment({
    required String appointmentId,
    required String reason,
  }) async {
    final apptRef = _db.collection('appointments').doc(appointmentId);
    final apptSnap = await apptRef.get();
    if (!apptSnap.exists) throw StateError('Appointment not found.');
    final apptData = apptSnap.data()!;
    final patientUid = (apptData['userId'] ?? '').toString();
    final doctorName = (apptData['doctorName'] ?? 'Specialist Doctor').toString();
    final activeKey = apptData['activeBookingKey']?.toString();

    await SchedulingService.releaseSlotAndLock(appointmentId);
    await apptRef.update({
      'status': 'rejected',
      'rejectionReason': reason.trim(),
      'updatedAt': FieldValue.serverTimestamp(),
    });

    if (activeKey != null && activeKey.isNotEmpty) {
      try {
        await _db.collection('active_bookings').doc(activeKey).delete();
      } catch (_) {}
    } else {
      final chamberId = (apptData['chamberId'] ?? '').toString();
      final doctorId = (apptData['doctorId'] ?? '').toString();
      final ts = apptData['scheduledTime'];
      if (patientUid.isNotEmpty && doctorId.isNotEmpty && ts is Timestamp) {
        final dt = ts.toDate();
        final dateKey = '${dt.year}-${dt.month.toString().padLeft(2, "0")}-${dt.day.toString().padLeft(2, "0")}';
        final fallbackKey = '${patientUid}_${doctorId}_${chamberId}_$dateKey';
        try {
          await _db.collection('active_bookings').doc(fallbackKey).delete();
        } catch (_) {}
      }
    }

    if (patientUid.isNotEmpty) {
      try {
        await NotificationService.createNotification(
          userId: patientUid,
          title: 'Appointment Request Declined',
          body: 'Your appointment request with $doctorName was declined. Reason: ${reason.trim()}.',
          type: 'appointment_rejected',
          relatedId: appointmentId,
        );
      } catch (_) {}
    }
  }

  /// Patient cancels their own appointment.
  static Future<void> cancelAppointmentByPatient(String appointmentId) async {
    final apptRef = _db.collection('appointments').doc(appointmentId);
    final apptSnap = await apptRef.get();
    final apptData = apptSnap.data() ?? {};
    final activeKey = apptData['activeBookingKey']?.toString();
    final patientUid = (apptData['userId'] ?? '').toString();

    await QueueService.cancelByPatient(appointmentId);
    await SchedulingService.releaseSlotAndLock(appointmentId);

    if (activeKey != null && activeKey.isNotEmpty) {
      try {
        await _db.collection('active_bookings').doc(activeKey).delete();
      } catch (_) {}
    } else {
      final chamberId = (apptData['chamberId'] ?? '').toString();
      final doctorId = (apptData['doctorId'] ?? '').toString();
      final ts = apptData['scheduledTime'];
      if (patientUid.isNotEmpty && doctorId.isNotEmpty && ts is Timestamp) {
        final dt = ts.toDate();
        final dateKey = '${dt.year}-${dt.month.toString().padLeft(2, "0")}-${dt.day.toString().padLeft(2, "0")}';
        final fallbackKey = '${patientUid}_${doctorId}_${chamberId}_$dateKey';
        try {
          await _db.collection('active_bookings').doc(fallbackKey).delete();
        } catch (_) {}
      }
    }
  }

  /// Fetches test appointments (missing or legacy status like 'waiting', empty status, etc.)
  static Future<List<Map<String, dynamic>>> fetchTestAppointments() async {
    final snap = await _db.collection('appointments').limit(100).get();
    const validStatuses = {'requested', 'confirmed', 'in_progress', 'done', 'cancelled', 'rejected'};
    final results = <Map<String, dynamic>>[];
    for (final doc in snap.docs) {
      final data = doc.data();
      final status = (data['status'] ?? '').toString();
      if (!validStatuses.contains(status)) {
        results.add({'id': doc.id, ...data});
      }
    }
    return results;
  }

  /// Individually deletes a single test appointment document.
  static Future<void> deleteTestAppointment(String appointmentId) async {
    await _db.collection('appointments').doc(appointmentId).delete();
  }

  static Future<void> softHideDoctor({
    required String doctorId,
    required String reason,
    required String adminUid,
  }) async {
    final docRef = _db.collection('doctors').doc(doctorId);
    await docRef.set({
      'hidden': true,
      'isHidden': true,
      'hiddenReason': reason.trim(),
      'hiddenBy': adminUid,
      'hiddenAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    try {
      final prefs = await SharedPreferences.getInstance();
      final hiddenList = prefs.getStringList('hidden_doctor_ids') ?? [];
      if (!hiddenList.contains(doctorId)) {
        hiddenList.add(doctorId);
        await prefs.setStringList('hidden_doctor_ids', hiddenList);
      }
    } catch (_) {}
  }

  static Future<void> restoreDoctor(String doctorId) async {
    final docRef = _db.collection('doctors').doc(doctorId);
    await docRef.set({
      'hidden': false,
      'isHidden': false,
      'isDeleted': false,
      'hiddenReason': FieldValue.delete(),
      'hiddenBy': FieldValue.delete(),
      'hiddenAt': FieldValue.delete(),
      'deletedAt': FieldValue.delete(),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    try {
      final prefs = await SharedPreferences.getInstance();
      final hiddenList = prefs.getStringList('hidden_doctor_ids') ?? [];
      hiddenList.remove(doctorId);
      await prefs.setStringList('hidden_doctor_ids', hiddenList);

      final deletedList = prefs.getStringList('deleted_doctor_ids') ?? [];
      deletedList.remove(doctorId);
      await prefs.setStringList('deleted_doctor_ids', deletedList);
    } catch (_) {}
  }

  static Future<void> hardDeleteDoctor({
    required String doctorId,
    bool isBundled = true,
  }) async {
    final docRef = _db.collection('doctors').doc(doctorId);
    await docRef.set({
      'isDeleted': true,
      'deletedAt': FieldValue.serverTimestamp(),
      'hidden': true,
      'isHidden': true,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    try {
      final prefs = await SharedPreferences.getInstance();
      final deletedList = prefs.getStringList('deleted_doctor_ids') ?? [];
      if (!deletedList.contains(doctorId)) {
        deletedList.add(doctorId);
        await prefs.setStringList('deleted_doctor_ids', deletedList);
      }
    } catch (_) {}
  }

  /// Desk calls the patient in: confirmed/checked_in -> in_consultation. The
  /// visit stays in the queue view until it is marked done.
  static Future<void> markAppointmentInProgress(String appointmentId) {
    return QueueService.startConsultation(appointmentId);
  }

  /// Returns true when a follow-up chat was unlocked for the patient.
  static Future<bool> markAppointmentCompletedAndUnlockChat(String appointmentId) async {
    final apptRef = _db.collection('appointments').doc(appointmentId);
    final apptSnap = await apptRef.get();
    if (!apptSnap.exists) return false;

    final apptData = apptSnap.data() ?? {};
    final patientUid = (apptData['userId'] ?? '').toString();
    final patientName = (apptData['patientName'] ?? 'Patient').toString();
    final doctorId = (apptData['doctorId'] ?? '').toString();
    final doctorName = (apptData['doctorName'] ?? 'Doctor').toString();

    // 1. Mark appointment completed ('done' aligns with AppointmentQueries.completedForChamber / completedForDoctor)
    await QueueService.finishVisit(appointmentId, outcome: ApptStatus.done);
    await SchedulingService.releaseSlotAndLock(appointmentId);

    // 2. Release active_bookings lock on completion
    final activeKey = apptData['activeBookingKey']?.toString();
    final chamberId = (apptData['chamberId'] ?? '').toString();
    final ts = apptData['scheduledTime'];
    if (activeKey != null && activeKey.isNotEmpty) {
      try {
        await _db.collection('active_bookings').doc(activeKey).delete();
      } catch (_) {}
    } else if (patientUid.isNotEmpty && doctorId.isNotEmpty && ts is Timestamp) {
      final dt = ts.toDate();
      final dateKey = '${dt.year}-${dt.month.toString().padLeft(2, "0")}-${dt.day.toString().padLeft(2, "0")}';
      final fallbackKey = '${patientUid}_${doctorId}_${chamberId}_$dateKey';
      try {
        await _db.collection('active_bookings').doc(fallbackKey).delete();
      } catch (_) {}
    }

    if (doctorId.isEmpty || patientUid.isEmpty) return false;

    // 2. Fetch doctor profile to check claimedByUid & messagingMode
    try {
      final docSnap = await _db.collection('doctors').doc(doctorId).get();
      if (!docSnap.exists) return false;

      final docData = docSnap.data() ?? {};
      final doctorUid = (docData['claimedByUid'] ?? '').toString();
      if (doctorUid.isEmpty) return false;

      final messagingMode = (docData['messagingMode'] ?? 'followup').toString();
      if (messagingMode == 'off' || messagingMode == 'paid') {
        return false;
      }

      final followupDays = (docData['followupDays'] as num?)?.toInt() ?? 7;
      final followupMaxMessages = (docData['followupMaxMessages'] as num?)?.toInt() ?? 20;

      await ChatService.unlockChatForCare(
        doctorUid: doctorUid,
        patientUid: patientUid,
        doctorName: doctorName,
        patientName: patientName,
        doctorId: doctorId,
        unlockedBy: appointmentId,
        chamberId: chamberId,
        followupDays: followupDays,
        followupMaxMessages: followupMaxMessages,
      );
      return true;
    } catch (e) {
      debugPrint('Error unlocking follow-up chat: $e');
      return false;
    }
  }

}
