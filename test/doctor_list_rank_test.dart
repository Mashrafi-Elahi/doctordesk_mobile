import 'package:flutter_test/flutter_test.dart';
import 'package:doctordesk/models/doctor.dart';

Doctor _doc(String id, {bool claimed = false, bool verified = false}) => Doctor.fromJson({
      'id': id,
      'name': id,
      'specialities': const ['Medicine'],
      if (claimed) 'claimedByUid': 'uid-$id',
      'isBmdcVerified': verified,
      if (verified) 'verificationStatus': 'verified',
    });

void main() {
  test('claimed + verified, claimed, verified, rest; order kept inside a rank', () {
    final sorted = Doctor.sortForListing([
      _doc('plain1'),
      _doc('verifiedOnly', verified: true),
      _doc('claimedOnly', claimed: true),
      _doc('plain2'),
      _doc('claimedVerified', claimed: true, verified: true),
    ]);
    expect(sorted.map((d) => d.id),
        ['claimedVerified', 'claimedOnly', 'verifiedOnly', 'plain1', 'plain2']);
  });

  test('unclaimed profiles are not bookable', () {
    expect(_doc('x').isClaimedProfile, isFalse);
    expect(_doc('y', claimed: true).isClaimedProfile, isTrue);
  });
}
