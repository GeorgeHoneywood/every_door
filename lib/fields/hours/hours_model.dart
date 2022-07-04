// ignore_for_file: prefer_initializing_formals

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

import 'days_range.dart';

class StringTime implements Comparable {
  late final String _time;

  StringTime(String time) {
    final pos = time.indexOf(':');
    if (!((time.length == 4 && pos == 1) || (time.length == 5 && pos == 2)))
      throw ArgumentError('Incorrect time: $time');
    _time = time.length < 5 ? '0' + time : time;
  }

  bool get is2400 => _time == '23:59' || _time == '00:00' || _time == '24:00';
  StringTime fix_2400() => is2400 ? StringTime('24:00') : this;
  bool get isRound => _time.endsWith(':00');
  int get hour => int.parse(_time.substring(0, 2));
  int get minute => int.parse(_time.substring(3));

  @override
  String toString() => _time;

  @override
  int compareTo(other) => _time.compareTo((other as StringTime)._time);

  @override
  bool operator ==(other) => other is StringTime && _time == other._time;
  bool operator <(StringTime other) => _time.compareTo(other._time) < 0;
  bool operator >(StringTime other) => _time.compareTo(other._time) > 0;
  bool operator <=(StringTime other) => _time.compareTo(other._time) <= 0;
  bool operator >=(StringTime other) => _time.compareTo(other._time) >= 0;

  @override
  int get hashCode => _time.hashCode;
}

class HoursInterval implements Comparable {
  final StringTime start;
  final StringTime end;

  HoursInterval(this.start, StringTime end) : end = end.fix_2400();

  HoursInterval.str(String start, String end)
      : start = StringTime(start),
        end = StringTime(end).fix_2400();

  HoursInterval.full()
      : start = StringTime('00:00'),
        end = StringTime('24:00');

  static final kReInterval = RegExp(r'(\d?\d:\d\d)\s*-\s*(\d?\d:\d\d)');

  factory HoursInterval.parse(String interval) {
    final hoursMatch = kReInterval.firstMatch(interval.trim());
    if (hoursMatch == null)
      throw HoursParsingException('No hours interval: $interval');
    try {
      return HoursInterval.str(hoursMatch.group(1)!, hoursMatch.group(2)!);
    } on ArgumentError {
      throw HoursParsingException('Failed to parse time in $interval');
    }
  }

  bool get isAllDay => start.is2400 && end.is2400;
  bool get crossesMidnight => start > end || end > StringTime('24:00');
  bool get isEmpty => start == end;
  bool get isNotEmpty => start != end;
  bool get overMidnight => start > end;

  @override
  String toString() => '$start-$end';

  @override
  bool operator ==(Object other) {
    return other is HoursInterval && other.start == start && other.end == end;
  }

  @override
  int get hashCode => start.hashCode + end.hashCode;

  @override
  int compareTo(other) {
    if (other is! HoursInterval) throw ArgumentError();
    int value = start.compareTo(other.start);
    if (value == 0) value = end.compareTo(other.end);
    return value;
  }

  // TODO: 24h rollover
  bool contains(other) => other.start >= start && other.end <= end;
  // TODO: 24h rollover
  bool intersects(other) =>
      (other.start <= end && other.end >= start) ||
      (other.end >= start && other.start <= end);
}

class HoursFragment implements Comparable {
  final DaysRange weekdays;
  HoursInterval? interval;
  List<HoursInterval> breaks;
  bool active;

  HoursFragment(this.weekdays, this.interval, this.breaks,
      {this.active = true}) {
    _fixAndSortBreaks();
  }

  /// Initializes with 24/7 equivalent: 7 weekdays, no PH, 00-24 interval.
  HoursFragment.make24()
      : weekdays = Weekdays.fullWeek(),
        interval = HoursInterval.full(),
        breaks = [],
        active = true;

  HoursFragment.inactive(this.weekdays)
      : interval = null,
        breaks = [],
        active = false;

  HoursFragment copyWith(
      {DaysRange? weekdays,
      HoursInterval? interval,
      List<HoursInterval>? breaks,
      bool? active}) {
    return HoursFragment(
      weekdays ?? this.weekdays,
      interval ?? this.interval,
      breaks ?? this.breaks,
      active: active ?? this.active,
    );
  }

  bool get isEmpty => weekdays.isEmpty;
  bool get is24h => breaks.isEmpty && (interval?.isAllDay ?? false);
  bool get is24_7 => is24h && weekdays is Weekdays && weekdays.isFull;

  /// Given interval and breaks, adds a new interval to maintain
  /// the breaks order. E.g. 6-14 + 15-21 = 6-21 + break 14-15.
  addInterval(HoursInterval other) {
    if (interval == null) {
      // Given an empty fragment, initialize it with the given interval.
      interval = other;
      breaks.clear();
    } else if (other.start > interval!.end) {
      // Other interval starts after the current.
      breaks.add(HoursInterval(interval!.end, other.start));
      interval = HoursInterval(interval!.start, other.end);
    } else if (other.end < interval!.start) {
      // Reverse case: other is before the current interval.
      breaks.insert(0, HoursInterval(other.end, interval!.start));
      interval = HoursInterval(other.start, interval!.end);
    } else if (breaks.isNotEmpty) {
      // Interval overlaps other: supporting breaks is hard.
      throw HoursParsingException(
          'Not supporting overlapping intervals with breaks. Interval $interval, new one $other.');
    } else {
      // No breaks and overlapping intervals: just merge.
      interval = HoursInterval(
        other.start < interval!.start ? other.start : interval!.start,
        other.end > interval!.end ? other.end : interval!.end,
      );
    }
  }

  updateInterval(HoursInterval? newInterval) {
    interval = newInterval;
    _fixAndSortBreaks();
  }

  addBreak(HoursInterval br) {
    if (interval == null)
      throw ArgumentError('Cannot add a break to a disabled fragment.');
    breaks.add(br);
    _fixAndSortBreaks();
  }

  _fixAndSortBreaks() {
    if (interval == null) breaks.clear();
    if (breaks.isEmpty) return;

    breaks.sort();
    for (int i = breaks.length - 1; i >= 1; i--) {
      if (breaks[i - 1].end >= breaks[i].start) {
        if (breaks[i - 1].end < breaks[i].end)
          breaks[i - 1] = HoursInterval(breaks[i - 1].start, breaks[i].end);
        breaks.removeAt(i);
      }
    }

    while (breaks.isNotEmpty && breaks.first.start <= interval!.start) {
      if (breaks.first.end >= interval!.end) {
        interval = null;
        breaks.clear();
        return;
      }
      if (breaks.first.end > interval!.start)
        interval = HoursInterval(breaks.first.end, interval!.end);
      breaks.removeAt(0);
    }

    while (breaks.isNotEmpty && breaks.last.end >= interval!.end) {
      if (breaks.last.start <= interval!.start) {
        interval = null;
        breaks.clear();
        return;
      }
      if (breaks.last.start < interval!.end)
        interval = HoursInterval(interval!.start, breaks.last.start);
      breaks.removeLast();
    }
  }

  @override
  bool operator ==(Object other) {
    if (other is! HoursFragment) return false;
    return weekdays == other.weekdays && intervalsEquals(other);
  }

  /// Compares time intervals, but not weekdays.
  bool intervalsEquals(HoursFragment other) =>
      interval == other.interval && listEquals(breaks, other.breaks);

  @override
  int get hashCode => weekdays.hashCode + interval.hashCode + breaks.hashCode;

  @override
  int compareTo(other) {
    if (other is! HoursFragment) throw ArgumentError();
    final wd = weekdays.compareTo(other.weekdays);
    if (wd != 0) return wd;
    return interval?.compareTo(other.interval) ?? 0;
  }

  String timeToString() {
    if (interval == null) return 'off';

    List<StringTime> hours = [
      for (final b in breaks) ...[b.start, b.end]
    ];
    hours.insert(0, interval!.start);
    hours.add(interval!.end);
    List<String> intervals = [
      for (int i = 0; i < hours.length; i += 2) '${hours[i]}-${hours[i + 1]}'
    ];
    return intervals.join(',');
  }

  @override
  String toString() =>
      'HoursFragment(${weekdays.makeString()} ${timeToString()}${active ? "" : " inactive"})';
}

class CollectionFragment implements Comparable {
  final Weekdays weekdays;
  List<StringTime> times;

  CollectionFragment(this.weekdays, this.times);

  bool get isAllWeek => weekdays.isFull;
  bool get isEmpty => weekdays.isEmpty || times.isEmpty;

  @override
  bool operator ==(Object other) {
    if (other is! CollectionFragment) return false;
    return weekdays == other.weekdays && listEquals(times, other.times);
  }

  @override
  int get hashCode => weekdays.hashCode + times.hashCode;

  @override
  int compareTo(other) {
    if (other is! CollectionFragment) throw ArgumentError();
    final wd = weekdays.compareTo(other.weekdays);
    if (wd != 0) return wd;
    for (int i = 0; i < times.length; i++) {
      if (i >= other.times.length) return 1;
      final tc = times[i].compareTo(other.times[i]);
      if (tc != 0) return tc;
    }
    return other.times.length > times.length ? -1 : 0;
  }

  @override
  String toString() {
    if (times.isEmpty) return '$weekdays off';
    final hours = times.map((t) => t.toString()).join(',');
    return '$weekdays $hours';
  }
}

class HoursData {
  static final _logger = Logger('HoursData');

  String hours;
  List<HoursFragment> fragments;

  HoursData(this.hours) : fragments = [] {
    try {
      _parseHours();
    } on HoursParsingException catch (e) {
      _logger.info('Could not parse opening_hours: ${e.message}');
      fragments = [];
    }
  }

  bool get raw => hours.isNotEmpty && fragments.isEmpty;
  bool get isEmpty => hours.isEmpty;

  static final kReHoursPart = RegExp(
    r'^[,; ]*([a-w][a-u][a-z0-9, [\]-]*:?\s+)?(\d?\d:\d\d\s*-\s*\d?\d:\d\d|off|closed)',
    caseSensitive: false,
  );

  _parseHours() {
    hours = hours.trim();
    if (hours == '24/7') {
      this.fragments = [HoursFragment.make24()];
      return;
    }

    this.fragments = [];
    if (hours.isEmpty) return;

    List<HoursFragment> fragments = [];
    int lastIndex = 0;
    int lastCount = 0;
    var match = kReHoursPart.matchAsPrefix(hours, lastIndex);
    while (match != null) {
      try {
        final time = match.group(2)!.toLowerCase();
        HoursInterval? interval = time == 'off' || time == 'closed'
            ? null
            : HoursInterval.parse(time);
        if (match.group(1) == null && fragments.isNotEmpty) {
          if (interval == null)
            throw HoursParsingException(
                'In hours, "off" should not follow a time: $hours');
          for (int i = 0; i < lastCount; i++)
            fragments[fragments.length - i - 1].addInterval(interval);
        } else {
          List<DaysRange> days = DaysRange.parse(match.group(1));
          if (days.isEmpty) days.add(Weekdays.fullWeek());
          for (final day in days)
            fragments.add(HoursFragment(day, interval, []));
          lastCount = days.length;
        }
      } on HoursParsingException {
        return;
      }

      lastIndex += match.end;
      match = kReHoursPart.matchAsPrefix(hours.substring(lastIndex));
    }

    _sortAndDeduplicate(fragments);
    final complete = RegExp(r'^[;, ]*$').hasMatch(hours.substring(lastIndex));
    this.fragments = complete ? fragments : [];
  }

  _sortAndDeduplicate(List<HoursFragment> fragments) {
    fragments.sort();
    for (int i = fragments.length - 1; i > 0; i--) {
      if (fragments[i].weekdays.runtimeType ==
          fragments[i - 1].weekdays.runtimeType) {
        if (fragments[i].intervalsEquals(fragments[i - 1])) {
          final merged = fragments[i].weekdays.merge(fragments[i - 1].weekdays);
          if (merged != null) {
            fragments[i - 1] = fragments[i - 1].copyWith(weekdays: merged);
            fragments.removeAt(i);
          }
        }
      }
    }
  }

  String buildHours() {
    if (this.fragments.isEmpty) return hours;
    if (this.fragments.first.is24_7) return '24/7';

    // Sort and remove duplicates.
    final fragments = List.of(this.fragments.where((f) => f.active));
    _sortAndDeduplicate(fragments);

    // TODO: When a fragments rolls over midnight, join with ','.
    final parts = <String>[];
    final skip = <int>{};
    for (int i = 0; i < fragments.length; i++) {
      if (skip.contains(i)) continue;
      final f = fragments[i];
      final weekdayParts = [f.weekdays.makeString()];
      if (f.weekdays.canBeJoinedToWeekdays) {
        for (int j = i + 1; j < fragments.length; j++) {
          if (fragments[j].weekdays.canBeJoinedToWeekdays &&
              f.intervalsEquals(fragments[j])) {
            weekdayParts.add(fragments[j].weekdays.makeString());
            skip.add(j);
          }
        }
      }
      final dayPrefix =
          f.weekdays == Weekdays.fullWeek() && weekdayParts.length == 1
              ? ''
              : weekdayParts.join(',') + ' ';
      parts.add('$dayPrefix${f.timeToString()}');
    }
    return parts.join('; ');
  }

  updateHours(String newHours) {
    hours = newHours.trim();
  }

  DaysRange getMissingWeekdays() {
    List<bool> daysSet = List.filled(7, false);
    bool seenPH = false;
    for (final f in fragments) {
      if (f.active) {
        if (f.weekdays is PublicHolidays) seenPH = true;
        if (f.weekdays is Weekdays) {
          for (int i = 0; i < daysSet.length; i++)
            daysSet[i] = daysSet[i] || (f.weekdays as Weekdays).days[i];
        }
      }
    }
    final result = Weekdays(daysSet.map((d) => !d).toList());
    if (result.isEmpty && !seenPH) return PublicHolidays();
    return result;
  }
}
