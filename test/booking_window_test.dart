import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doctordesk/services/scheduling_service.dart';

void main() {
  final today = SchedulingService.today;

  // Open every day until a minute before midnight, so "today" stays bookable
  // whenever the test runs.
  const allDay = ParsedSchedule(
    start: TimeOfDay(hour: 0, minute: 0),
    end: TimeOfDay(hour: 23, minute: 59),
    visitingDays: [1, 2, 3, 4, 5, 6, 7],
  );

  DateTime nextWeekday(int weekday) {
    var d = today.add(const Duration(days: 1));
    while (d.weekday != weekday) {
      d = d.add(const Duration(days: 1));
    }
    return d;
  }

  group('booking window', () {
    test('covers today plus the next 14 days', () {
      expect(SchedulingService.bookingWindow.length, 15);
      expect(SchedulingService.bookingWindow.first, today);
      expect(SchedulingService.lastBookableDate, today.add(const Duration(days: 14)));
    });

    test('days outside the window are not bookable', () {
      final yesterday = today.subtract(const Duration(days: 1));
      final day15 = today.add(const Duration(days: 15));
      expect(SchedulingService.isBookableDay(yesterday, schedule: allDay), isFalse);
      expect(SchedulingService.isBookableDay(day15, schedule: allDay), isFalse);
      expect(SchedulingService.isBookableDay(SchedulingService.lastBookableDate, schedule: allDay), isTrue);
    });

    test('today is bookable only before the chamber closes', () {
      expect(SchedulingService.isBookableDay(today, schedule: allDay), isTrue);
      const closedAtMidnight = ParsedSchedule(
        start: TimeOfDay(hour: 0, minute: 0),
        end: TimeOfDay(hour: 0, minute: 0),
        visitingDays: [1, 2, 3, 4, 5, 6, 7],
      );
      expect(SchedulingService.isBookableDay(today, schedule: closedAtMidnight), isFalse);
    });
  });

  group('visiting days and overrides', () {
    const satToThu = ParsedSchedule(
      start: TimeOfDay(hour: 17, minute: 0),
      end: TimeOfDay(hour: 21, minute: 0),
    );
    final friday = nextWeekday(DateTime.friday);
    final saturday = nextWeekday(DateTime.saturday);

    test('a non-visiting day is off unless the desk opens it', () {
      expect(SchedulingService.isBookableDay(friday, schedule: satToThu), isFalse);
      expect(
        SchedulingService.isBookableDay(friday, schedule: satToThu, overrides: {
          SchedulingService.dateKey(friday): {'status': 'open'},
        }),
        isTrue,
      );
    });

    test('closed or full days are never bookable', () {
      for (final status in ['closed', 'full']) {
        expect(
          SchedulingService.isBookableDay(saturday, schedule: satToThu, overrides: {
            SchedulingService.dateKey(saturday): {'status': status},
          }),
          isFalse,
          reason: status,
        );
      }
    });

    test('unknown hours leave every day in the window open', () {
      expect(SchedulingService.isBookableDay(friday), isTrue);
    });

    test('firstBookableDay skips days that are off', () {
      final first = SchedulingService.firstBookableDay(from: friday, schedule: satToThu);
      expect(first, isNotNull);
      expect(first!.weekday, isNot(DateTime.friday));
    });
  });
}
