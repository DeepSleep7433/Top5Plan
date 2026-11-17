import 'package:intl/intl.dart';
import 'package:timezone/timezone.dart' as tz;

class AccountClock {
  AccountClock(this.timezone);

  final String timezone;

  tz.Location get location {
    try {
      return tz.getLocation(timezone);
    } catch (_) {
      return tz.getLocation('Asia/Shanghai');
    }
  }

  tz.TZDateTime now() => tz.TZDateTime.now(location);

  String today() => DateFormat('yyyy-MM-dd').format(now());

  String dateOf(DateTime value) =>
      DateFormat('yyyy-MM-dd').format(tz.TZDateTime.from(value, location));

  DateTime startOfDayUtc(String businessDate) {
    final parts = businessDate.split('-').map(int.parse).toList();
    return tz.TZDateTime(location, parts[0], parts[1], parts[2]).toUtc();
  }

  DateTime endOfDayUtc(String businessDate) =>
      tz.TZDateTime(location, int.parse(businessDate.substring(0, 4)),
              int.parse(businessDate.substring(5, 7)), int.parse(businessDate.substring(8, 10)))
          .add(const Duration(days: 1))
          .toUtc();

  String formatDateTime(DateTime value) =>
      DateFormat('MM-dd HH:mm').format(tz.TZDateTime.from(value, location));

  String formatTime(DateTime value) =>
      DateFormat('HH:mm').format(tz.TZDateTime.from(value, location));

  String weekday(String date) {
    final d = DateTime.parse(date);
    const names = ['一', '二', '三', '四', '五', '六', '日'];
    return '周${names[d.weekday - 1]}';
  }
}
