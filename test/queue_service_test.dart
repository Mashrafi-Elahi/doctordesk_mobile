import 'package:flutter_test/flutter_test.dart';
import 'package:doctordesk/services/queue_service.dart';

void main() {
  group('QueueService lifecycle', () {
    test('allows the normal path request -> propose -> confirm -> visit -> done', () {
      expect(QueueService.canTransition('requested', ApptStatus.proposed), isTrue);
      expect(QueueService.canTransition('proposed', ApptStatus.confirmed), isTrue);
      expect(QueueService.canTransition('confirmed', ApptStatus.checkedIn), isTrue);
      expect(QueueService.canTransition('checked_in', ApptStatus.inConsultation), isTrue);
      expect(QueueService.canTransition('in_consultation', ApptStatus.done), isTrue);
    });

    test('refuses skipped or backwards steps', () {
      expect(QueueService.canTransition('requested', ApptStatus.done), isFalse);
      expect(QueueService.canTransition('requested', ApptStatus.checkedIn), isFalse);
      expect(QueueService.canTransition('done', ApptStatus.confirmed), isFalse);
      expect(QueueService.canTransition('checked_in', ApptStatus.confirmed), isFalse);
      expect(QueueService.canTransition('cancelled', ApptStatus.confirmed), isFalse);
    });

    test('maps legacy statuses', () {
      expect(QueueService.normalizeStatus('in_progress'), ApptStatus.inConsultation);
      expect(QueueService.normalizeStatus('completed'), ApptStatus.done);
      expect(QueueService.canTransition('in_progress', ApptStatus.done), isTrue);
    });
  });

  group('QueueService tokens', () {
    test('queue ID is per chamber, doctor and day', () {
      expect(QueueService.queueId('ch1', 'docA', DateTime(2030, 1, 5, 18, 30)),
          'ch1_docA_20300105');
      expect(QueueService.queueId('ch1', 'docB', DateTime(2030, 1, 5)),
          isNot(QueueService.queueId('ch1', 'docA', DateTime(2030, 1, 5))));
    });

    test('next token never reuses a number, including legacy lastQueuePosition', () {
      expect(QueueService.nextToken(null), 1);
      expect(QueueService.nextToken({'lastNumber': 4}), 5);
      expect(QueueService.nextToken({'lastNumber': 4, 'lastQueuePosition': 9}), 10);
    });

    test('people ahead counts only lower tokens still waiting', () {
      expect(QueueService.peopleAhead([3, 5, 8, 12], 12), 3);
      expect(QueueService.peopleAhead([3, 5, 8, 12], 3), 0);
      expect(QueueService.peopleAhead([], 7), 0);
    });

    test('joining adds the token once and keeps the list sorted', () {
      final w = QueueService.joinWrite({'lastNumber': 2, 'waitingTokens': [2, 1]},
          chamberId: 'c', doctorId: 'd', date: '20300101', token: 3, appointmentId: 'a');
      expect(w['waitingTokens'], [1, 2, 3]);
      expect(w['waitingCount'], 3);
      expect(w['lastNumber'], 3);
    });

    test('leaving removes the token and resets serving when the queue empties', () {
      final busy = QueueService.leaveWrite(
          {'waitingTokens': [4, 5], 'currentServing': 3, 'currentAppointmentId': 'x'},
          token: 4, appointmentId: 'a');
      expect(busy['waitingTokens'], [5]);
      expect(busy.containsKey('currentServing'), isFalse);

      final empty = QueueService.leaveWrite(
          {'waitingTokens': [5], 'currentServing': 4, 'currentAppointmentId': ''},
          token: 5, appointmentId: 'a');
      expect(empty['waitingTokens'], isEmpty);
      expect(empty['waitingCount'], 0);
      expect(empty['currentServing'], 0);
    });
  });
}
