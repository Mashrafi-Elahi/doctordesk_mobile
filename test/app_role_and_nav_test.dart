import 'package:flutter_test/flutter_test.dart';
import 'package:doctordesk/widgets/app_role_and_nav.dart';

void main() {
  group('AppBottomNavConfig & UserRoles tests', () {
    test('provides single source of truth for third tab labels', () {
      expect(AppBottomNavConfig.thirdTabLabel(AppRole.patient), 'Appointments');
      expect(AppBottomNavConfig.thirdTabLabel(AppRole.doctor), 'Manage');
      expect(AppBottomNavConfig.thirdTabLabel(AppRole.operator), 'Desk');
    });

    // A doctor with no chamber yet needs the Manage tab to add their first one.
    test('shows third tab even when chamberCount == 0 for doctor/operator', () {
      const zeroChambers = UserRoles(isDoctor: true, isOperator: true, chamberCount: 0);
      expect(AppBottomNavConfig.showThirdTab(AppRole.doctor, zeroChambers), isTrue);
      expect(AppBottomNavConfig.showThirdTab(AppRole.operator, zeroChambers), isTrue);
      // Patient tab always shows regardless of chambers
      expect(AppBottomNavConfig.showThirdTab(AppRole.patient, zeroChambers), isTrue);

      const withChambers = UserRoles(isDoctor: true, isOperator: true, chamberCount: 2);
      expect(AppBottomNavConfig.showThirdTab(AppRole.doctor, withChambers), isTrue);
      expect(AppBottomNavConfig.showThirdTab(AppRole.operator, withChambers), isTrue);
      expect(AppBottomNavConfig.showThirdTab(AppRole.patient, withChambers), isTrue);
    });

    test('UserRoles computes availableRoles and hasMultipleRoles correctly', () {
      const patientOnly = UserRoles(isDoctor: false, isOperator: false);
      expect(patientOnly.availableRoles, [AppRole.patient]);
      expect(patientOnly.hasMultipleRoles, isFalse);

      const doctorAndOperator = UserRoles(isDoctor: true, isOperator: true, chamberCount: 1);
      expect(doctorAndOperator.availableRoles, [AppRole.patient, AppRole.doctor, AppRole.operator]);
      expect(doctorAndOperator.hasMultipleRoles, isTrue);
    });

    test('UserRoles enforces feed, video, FAQ, and moderator permissions accurately', () {
      // 1. Patient: Cannot post video or answer FAQ, cannot manage moderators
      const patient = UserRoles();
      expect(patient.canPostVideo, isFalse);
      expect(patient.canPostFeed, isFalse);
      expect(patient.canAnswerFaq, isFalse);
      expect(patient.canManageModerators, isFalse);

      // 2. Operator: Cannot post video or answer FAQ, cannot manage moderators
      const operatorUser = UserRoles(isOperator: true);
      expect(operatorUser.canPostVideo, isFalse);
      expect(operatorUser.canPostFeed, isFalse);
      expect(operatorUser.canAnswerFaq, isFalse);
      expect(operatorUser.canManageModerators, isFalse);

      // 3. Doctor: Can post video, feed tips, answer FAQ, but cannot manage moderators
      const doctor = UserRoles(isDoctor: true);
      expect(doctor.canPostVideo, isTrue);
      expect(doctor.canPostFeed, isTrue);
      expect(doctor.canAnswerFaq, isTrue);
      expect(doctor.canManageModerators, isFalse);

      // 4. Moderator: Can post video, tips, answer FAQ, but cannot remove/manage moderators
      const moderator = UserRoles(isModerator: true);
      expect(moderator.canPostVideo, isTrue);
      expect(moderator.canPostFeed, isTrue);
      expect(moderator.canAnswerFaq, isTrue);
      expect(moderator.canManageModerators, isFalse);

      // 5. Admin: Can do all, and CAN manage/appoint/remove moderators
      const admin = UserRoles(isAdmin: true);
      expect(admin.canPostVideo, isTrue);
      expect(admin.canPostFeed, isTrue);
      expect(admin.canAnswerFaq, isTrue);
      expect(admin.canManageModerators, isTrue);
    });
  });
}
