import 'package:doctordesk/services/device_location.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(DeviceLocation.resetFailure);

  test('a failed fix hides device location for 10 minutes', () {
    final failedAt = DateTime(2026, 11, 2, 10);
    expect(DeviceLocation.recentlyFailed(now: failedAt), isFalse);

    DeviceLocation.recordFailure(failedAt);
    expect(DeviceLocation.recentlyFailed(now: failedAt.add(const Duration(minutes: 9))), isTrue);
    expect(DeviceLocation.recentlyFailed(now: failedAt.add(const Duration(minutes: 10))), isFalse);
  });
}
