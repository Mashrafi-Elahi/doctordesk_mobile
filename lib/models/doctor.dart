import '../widgets/chamber_accessibility.dart';

class Chamber {
  final String? id;
  final String? hospitalName;
  final String? area;
  final String? location;
  final double? lat;
  final double? lng;
  final String? visitingHours;
  final int? fee;
  final ChamberAccessibility? accessibility;
  final bool isAccessible;
  final List<String> accessibilityFeatures;
  final bool hasOperator;
  final String? operatorUid;
  final String? operatorName;
  final String? operatorEmail;
  final int slotMinutes;

  Chamber({
    this.id,
    this.hospitalName,
    this.area,
    this.location,
    this.lat,
    this.lng,
    this.visitingHours,
    this.fee,
    this.accessibility,
    this.isAccessible = false,
    this.accessibilityFeatures = const [],
    this.hasOperator = false,
    this.operatorUid,
    this.operatorName,
    this.operatorEmail,
    this.slotMinutes = 10,
  });

  factory Chamber.fromJson(Map<String, dynamic> json) {
    ChamberAccessibility? accessibility;
    if (json['accessibility'] != null && json['accessibility'] is Map<String, dynamic>) {
      accessibility = ChamberAccessibility.fromJson(json['accessibility'] as Map<String, dynamic>);
    } else if (json['wheelchairEntrance'] != null) {
      accessibility = ChamberAccessibility.fromJson(json);
    }

    final bool rawIsAccessible = (json['isAccessible'] as bool?) ??
        (accessibility?.wheelchairEntrance == true);

    final List<String> features = [];
    if (json['accessibilityFeatures'] != null && json['accessibilityFeatures'] is List) {
      features.addAll((json['accessibilityFeatures'] as List).map((e) => e.toString()));
    } else {
      if (json['wheelchairEntrance'] == true) features.add('Ramp');
      if (json['liftAvailable'] == true) features.add('Lift/Elevator');
      if (json['accessibleToilet'] == true) features.add('Accessible washroom');
    }

    return Chamber(
      id: json['id'] as String?,
      hospitalName: (json['hospitalName'] ?? json['name']) as String?,
      area: json['area'] as String?,
      location: json['location'] as String?,
      lat: (json['lat'] as num?)?.toDouble(),
      lng: (json['lng'] as num?)?.toDouble(),
      // Saved as text on older chambers, {display, days, start, end} on newer.
      visitingHours: json['visitingHours'] is Map
          ? ((json['visitingHours'] as Map)['display'] ?? json['visitingHoursDisplay'])?.toString()
          : json['visitingHours'] as String?,
      fee: (json['fee'] as num?)?.toInt(),
      accessibility: accessibility,
      isAccessible: rawIsAccessible,
      accessibilityFeatures: features,
      hasOperator: json['hasOperator'] == true,
      operatorUid: json['operatorUid'] as String?,
      operatorName: json['operatorName'] as String?,
      operatorEmail: json['operatorEmail'] as String?,
      slotMinutes: (json['slotMinutes'] as num?)?.toInt() ?? 10,
    );
  }

  Map<String, dynamic> toJson() => {
    if (id != null) 'id': id,
    'hospitalName': hospitalName,
    'area': area,
    'location': location,
    if (lat != null) 'lat': lat,
    if (lng != null) 'lng': lng,
    if (visitingHours != null) 'visitingHours': visitingHours,
    if (fee != null) 'fee': fee,
    'accessibility': accessibility?.toJson(),
    'isAccessible': isAccessible,
    'accessibilityFeatures': accessibilityFeatures,
    'hasOperator': hasOperator,
    if (operatorUid != null) 'operatorUid': operatorUid,
    if (operatorName != null) 'operatorName': operatorName,
    if (operatorEmail != null) 'operatorEmail': operatorEmail,
    'slotMinutes': slotMinutes,
  };
}

class Doctor {
  final String id;
  final String name;
  final List<String> specialities;
  final double experienceYears;
  final List<String> education;
  final List<String> concentrations;
  final String? designation;
  final String? bmdcRegNumber;
  final String? bmdcNumber;
  final bool isBmdcVerified;
  final String verificationStatus;
  final dynamic verifiedAt;
  final String? verifiedBy;
  final bool isClaimed;
  final String? claimedByUid;
  final String claimStatus;
  final String? certificateImageUrl;
  final double? bayesianRating;
  final double? ratingAverage;
  final int ratingCount;
  final List<Chamber> chambers;
  final Chamber? chamber;
  final double? distance;
  final bool consultEnabled;
  final double consultFee;
  final String? consultAvailability;
  final bool isHidden;
  final String? hiddenReason;
  final String? hiddenBy;
  final dynamic hiddenAt;
  final bool isDeleted;
  final dynamic deletedAt;
  final String messagingMode; // 'off' | 'followup' | 'paid'
  final int followupDays;
  final int followupMaxMessages;

  Doctor({
    required this.id,
    required this.name,
    required this.specialities,
    required this.experienceYears,
    required this.education,
    required this.concentrations,
    this.designation,
    this.bmdcRegNumber,
    String? bmdcNumber,
    required this.isBmdcVerified,
    String? verificationStatus,
    this.verifiedAt,
    this.verifiedBy,
    this.isClaimed = false,
    this.claimedByUid,
    String? claimStatus,
    this.certificateImageUrl,
    this.bayesianRating,
    this.ratingAverage,
    required this.ratingCount,
    required this.chambers,
    this.chamber,
    this.distance,
    this.consultEnabled = false,
    this.consultFee = 500.0,
    this.consultAvailability,
    this.isHidden = false,
    this.hiddenReason,
    this.hiddenBy,
    this.hiddenAt,
    this.isDeleted = false,
    this.deletedAt,
    this.messagingMode = 'followup',
    this.followupDays = 7,
    this.followupMaxMessages = 20,
  })  : bmdcNumber = bmdcNumber ?? bmdcRegNumber,
        verificationStatus = verificationStatus ?? (isBmdcVerified ? 'verified' : 'unverified'),
        claimStatus = claimStatus ?? (claimedByUid != null || isClaimed ? 'claimed' : 'unclaimed');

  bool get hasAccessibleChamber {
    if (chamber?.isAccessible == true) return true;
    return chambers.any((c) => c.isAccessible);
  }

  /// Claimed = a real DoctorDesk account runs this profile, so it can be booked.
  bool get isClaimedProfile => claimedByUid?.trim().isNotEmpty ?? false;

  bool get isVerifiedProfile =>
      isBmdcVerified || verificationStatus == 'verified' || verificationStatus == 'checked_found';

  /// Listing order: 0 claimed + verified, 1 claimed, 2 verified only, 3 rest.
  int get listRank => isClaimedProfile ? (isVerifiedProfile ? 0 : 1) : (isVerifiedProfile ? 2 : 3);

  /// Stable sort by [listRank], keeping the incoming order (relevance,
  /// distance, name) within each rank.
  static List<Doctor> sortForListing(Iterable<Doctor> doctors) {
    final indexed = doctors.toList().asMap().entries.toList()
      ..sort((a, b) {
        final byRank = a.value.listRank.compareTo(b.value.listRank);
        return byRank != 0 ? byRank : a.key.compareTo(b.key);
      });
    return indexed.map((e) => e.value).toList();
  }

  Doctor copyWith({
    String? id,
    String? name,
    List<String>? specialities,
    double? experienceYears,
    List<String>? education,
    List<String>? concentrations,
    String? designation,
    String? bmdcRegNumber,
    String? bmdcNumber,
    bool? isBmdcVerified,
    String? verificationStatus,
    dynamic verifiedAt,
    String? verifiedBy,
    bool? isClaimed,
    String? claimedByUid,
    String? claimStatus,
    String? certificateImageUrl,
    double? bayesianRating,
    double? ratingAverage,
    int? ratingCount,
    List<Chamber>? chambers,
    Chamber? chamber,
    double? distance,
  }) {
    return Doctor(
      id: id ?? this.id,
      name: name ?? this.name,
      specialities: specialities ?? this.specialities,
      experienceYears: experienceYears ?? this.experienceYears,
      education: education ?? this.education,
      concentrations: concentrations ?? this.concentrations,
      designation: designation ?? this.designation,
      bmdcRegNumber: bmdcRegNumber ?? this.bmdcRegNumber,
      bmdcNumber: bmdcNumber ?? this.bmdcNumber,
      isBmdcVerified: isBmdcVerified ?? this.isBmdcVerified,
      verificationStatus: verificationStatus ?? this.verificationStatus,
      verifiedAt: verifiedAt ?? this.verifiedAt,
      verifiedBy: verifiedBy ?? this.verifiedBy,
      isClaimed: isClaimed ?? this.isClaimed,
      claimedByUid: claimedByUid ?? this.claimedByUid,
      claimStatus: claimStatus ?? this.claimStatus,
      certificateImageUrl: certificateImageUrl ?? this.certificateImageUrl,
      bayesianRating: bayesianRating ?? this.bayesianRating,
      ratingAverage: ratingAverage ?? this.ratingAverage,
      ratingCount: ratingCount ?? this.ratingCount,
      chambers: chambers ?? this.chambers,
      chamber: chamber ?? this.chamber,
      distance: distance ?? this.distance,
    );
  }

  factory Doctor.fromJson(Map<String, dynamic> json) {
    final List<Chamber> parsedChambers = [];
    if (json['chambers'] != null && json['chambers'] is List) {
      for (final c in json['chambers'] as List) {
        if (c is Map) {
          try {
            parsedChambers.add(Chamber.fromJson(Map<String, dynamic>.from(c)));
          } catch (_) {}
        }
      }
    }

    Chamber? parsedChamber;
    if (json['chamber'] != null && json['chamber'] is Map) {
      try {
        parsedChamber = Chamber.fromJson(Map<String, dynamic>.from(json['chamber'] as Map));
        if (parsedChambers.isEmpty) {
          parsedChambers.add(parsedChamber);
        }
      } catch (_) {}
    } else if (parsedChambers.isNotEmpty) {
      parsedChamber = parsedChambers.first;
    }

    final bmdc = (json['bmdcNumber'] ?? json['bmdcRegNumber'])?.toString();
    final isBmdcVer = json['isBmdcVerified'] == true || json['verificationStatus'] == 'verified';
    final verStatus = json['verificationStatus']?.toString() ?? (isBmdcVer ? 'verified' : 'unverified');
    final claimed = json['isClaimed'] == true || (json['claimedByUid'] != null && json['claimedByUid'].toString().isNotEmpty) || json['claimStatus'] == 'claimed';
    final cStatus = json['claimStatus']?.toString() ?? (claimed ? 'claimed' : 'unclaimed');

    return Doctor(
      id: (json['_id'] ?? json['id'] ?? '').toString(),
      name: json['name'] ?? '',
      specialities: (json['specialities'] as List?)?.map((e) => e.toString()).toList() ?? [],
      experienceYears: (json['experienceYears'] as num?)?.toDouble() ?? 0.0,
      education: (json['education'] as List?)?.map((e) => e.toString()).toList() ?? [],
      concentrations: (json['concentrations'] as List?)?.map((e) => e.toString()).toList() ?? [],
      designation: json['designation'],
      bmdcRegNumber: bmdc,
      bmdcNumber: bmdc,
      isBmdcVerified: isBmdcVer,
      verificationStatus: verStatus,
      verifiedAt: json['verifiedAt'],
      verifiedBy: json['verifiedBy']?.toString(),
      isClaimed: claimed,
      // Hidden/merged duplicates and soft-deleted profiles must not list.
      isHidden: json['hidden'] == true || json['isHidden'] == true,
      isDeleted: json['isDeleted'] == true,
      claimedByUid: json['claimedByUid']?.toString(),
      claimStatus: cStatus,
      certificateImageUrl: json['certificateImageUrl'],
      bayesianRating: (json['bayesianRating'] as num?)?.toDouble(),
      ratingAverage: (json['ratingAverage'] as num?)?.toDouble(),
      ratingCount: (json['ratingCount'] as num?)?.toInt() ?? 0,
      chambers: parsedChambers,
      chamber: parsedChamber,
      distance: (json['distance'] as num?)?.toDouble(),
    );
  }

  Map<String, dynamic> toJson() => {
    '_id': id,
    'id': id,
    'name': name,
    'specialities': specialities,
    'experienceYears': experienceYears,
    'education': education,
    'concentrations': concentrations,
    'designation': designation,
    'bmdcRegNumber': bmdcRegNumber,
    'bmdcNumber': bmdcNumber ?? bmdcRegNumber,
    'isBmdcVerified': isBmdcVerified,
    'verificationStatus': verificationStatus,
    if (verifiedAt != null) 'verifiedAt': verifiedAt,
    if (verifiedBy != null) 'verifiedBy': verifiedBy,
    'isClaimed': isClaimed,
    'claimedByUid': claimedByUid,
    'claimStatus': claimStatus,
    'certificateImageUrl': certificateImageUrl,
    'bayesianRating': bayesianRating,
    'ratingAverage': ratingAverage,
    'ratingCount': ratingCount,
    'chambers': chambers.map((c) => c.toJson()).toList(),
    'chamber': chamber?.toJson(),
    'distance': distance,
  };
}
