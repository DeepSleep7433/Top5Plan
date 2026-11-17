import 'package:flutter_test/flutter_test.dart';
import 'package:t5_plan/core/db/repository.dart';

void main() {
  test('monthly recurrence clamps to the last day of the month', () {
    expect(TaskRepository.nextRecurrenceDate(DateTime(2025, 1, 31), 'monthly'), DateTime(2025, 2, 28));
    expect(TaskRepository.nextRecurrenceDate(DateTime(2024, 1, 31), 'monthly'), DateTime(2024, 2, 29));
    expect(TaskRepository.nextRecurrenceDate(DateTime(2025, 12, 31), 'monthly'), DateTime(2026, 1, 31));
  });

  test('daily and weekly recurrence cross year boundaries', () {
    expect(TaskRepository.nextRecurrenceDate(DateTime(2025, 12, 31), 'daily'), DateTime(2026, 1, 1));
    expect(TaskRepository.nextRecurrenceDate(DateTime(2025, 12, 29), 'weekly'), DateTime(2026, 1, 5));
  });
}
