// ignore_for_file: use_build_context_synchronously
/// VECTOR Calendar — a Google Calendar-like month + day view.
///
/// Month grid with dots for busy days, a swipeable day agenda (all-day items
/// pinned at the top), a create/edit page, and a Hermes command bar.
/// Cupertino-only: no Material widgets, pull-to-refresh via slivers.
library;

import 'package:flutter/cupertino.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_client.dart';

void main() {
  // In release builds a widget whose build() throws is replaced by a
  // blank ErrorWidget that prints nothing, so the screen just goes white
  // and the device reports no reason. Surface it instead.
  ErrorWidget.builder = (FlutterErrorDetails d) => _CrashReport(d);
  runApp(const VectorCalendarApp());
}

/// Design language carried over from the existing app: frosted glass cards,
/// generous spacing, large bold headings, gradient background.
class AppColors {
  static const bgBase = Color(0xFFF5F5F7);
  static const bgTop = Color(0xFFEEF1FF);
  static const glass = Color(0xCCFFFFFF);
  static const accent = Color(0xFF6366F1);
  static const accentSoft = Color(0xFF8B5CF6);
  static const success = Color(0xFF10B981);
  static const danger = Color(0xFFEF4444);
  static const warning = Color(0xFFF59E0B);
  static const textPrimary = Color(0xFF1C1C1E);
  static const textSecondary = Color(0xFF6B7280);
  static const textTertiary = Color(0xFF9CA3AF);
}

// ---------------------------------------------------------------------------
// Date + item helpers (pure, so they cannot throw inside build).
// ---------------------------------------------------------------------------

String _two(int n) => n.toString().padLeft(2, '0');

/// Colour for a priority, 1 being the most important.
///
/// Paired with a visible P-label in the UI: colour alone is not readable for
/// everyone, and priority is the signal the scheduler ranks on.
Color _priColor(int p) {
  switch (p) {
    case 1:
      return AppColors.danger;
    case 2:
      return AppColors.warning;
    case 3:
      return AppColors.accent;
    case 4:
      return AppColors.textTertiary;
    default:
      return AppColors.textTertiary;
  }
}

/// 'YYYY-MM-DD' key used to group items per day.
String dayKey(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${_two(d.month)}-${_two(d.day)}';

DateTime dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

DateTime addDays(DateTime d, int n) => DateTime(d.year, d.month, d.day + n);

int daysInMonth(int year, int month) => DateTime(year, month + 1, 0).day;

String monthName(int m) {
  const names = [
    'January', 'February', 'March', 'April', 'May', 'June', 'July',
    'August', 'September', 'October', 'November', 'December',
  ];
  if (m < 1 || m > 12) return '';
  return names[m - 1];
}

String weekdayName(int w) {
  const names = [
    'Monday', 'Tuesday', 'Wednesday', 'Thursday',
    'Friday', 'Saturday', 'Sunday',
  ];
  if (w < 1 || w > 7) return '';
  return names[w - 1];
}

/// Parse `scheduled_at` ('YYYY-MM-DDTHH:MM:SS'); null when absent or bad.
DateTime? parseWhen(Map<String, dynamic> item) {
  final v = item['scheduled_at'];
  if (v is String && v.isNotEmpty) return DateTime.tryParse(v);
  return null;
}

/// all_day arrives as int 0/1 (or bool); anything else means timed.
bool itemIsAllDay(Map<String, dynamic> item) {
  final v = item['all_day'];
  if (v is num) return v.toInt() == 1;
  if (v is bool) return v;
  return false;
}

int itemMinutes(Map<String, dynamic> item) =>
    Safe.number(item['minutes'])?.toInt() ?? 30;

String itemTitle(Map<String, dynamic> item) =>
    (item['title'] ?? '').toString();

bool itemIsDone(Map<String, dynamic> item) =>
    (item['status'] ?? '').toString() == 'done';

/// A day laid out as an hour-by-hour grid.
///
/// The user's complaint was that the calendar "only show dates not hours", so
/// the day view is a real time grid: one row per hour, items drawn as blocks at
/// their actual time and sized by their duration. An agenda list is not a
/// calendar.
const int kDayStartHour = 5; // 05:00 - the range the user chose
const int kDayEndHour = 24; // through midnight
const double kHourHeight = 58.0;

int _startMin(Map<String, dynamic> item) {
  final w = parseWhen(item);
  if (w == null) return kDayStartHour * 60;
  final m = w.hour * 60 + w.minute;
  // An item outside the visible range is clamped to the edge rather than
  // dropped, so work before 05:00 is still visible instead of silently missing.
  final floor = kDayStartHour * 60;
  final ceil = kDayEndHour * 60 - 15;
  if (m < floor) return floor;
  if (m > ceil) return ceil;
  return m;
}

int _durMin(Map<String, dynamic> item) {
  final m = itemMinutes(item);
  // A very short block is unreadable in a grid, and a huge one would push the
  // rest off-screen; clamp for layout only, never in the data.
  if (m < 20) return 20;
  if (m > 240) return 240;
  return m;
}

/// One item positioned in the grid.
class _Placed {
  const _Placed(this.item, this.col, this.cols);
  final Map<String, dynamic> item;
  final int col;
  final int cols;

  double top() =>
      (_startMin(item) - kDayStartHour * 60) / 60.0 * kHourHeight;

  double height() => _durMin(item) / 60.0 * kHourHeight;
}

/// Assign overlapping items to columns so none is drawn on top of another.
///
/// Items are grouped into clusters of transitively-overlapping work; within a
/// cluster each item takes the first column that is free at its start. The
/// cluster's column count sets each block's width, so a lone item still spans
/// the full grid rather than a third of it.
List<_Placed> layoutDay(List<Map<String, dynamic>> timed) {
  final items = timed.toList()
    ..sort((a, b) {
      final s = _startMin(a).compareTo(_startMin(b));
      if (s != 0) return s;
      return itemTitle(a).compareTo(itemTitle(b));
    });

  final out = <_Placed>[];
  var cluster = <Map<String, dynamic>>[];
  var clusterEnd = -1;

  void flush() {
    if (cluster.isEmpty) return;
    final colEnds = <int>[];
    final colOf = <String, int>{};
    for (final it in cluster) {
      final s = _startMin(it);
      final e = s + _durMin(it);
      var placed = -1;
      for (var c = 0; c < colEnds.length; c++) {
        if (colEnds[c] <= s) {
          placed = c;
          colEnds[c] = e;
          break;
        }
      }
      if (placed == -1) {
        colEnds.add(e);
        placed = colEnds.length - 1;
      }
      colOf[(it['id'] ?? '').toString()] = placed;
    }
    for (final it in cluster) {
      out.add(_Placed(it, colOf[(it['id'] ?? '').toString()] ?? 0,
          colEnds.length));
    }
    cluster = <Map<String, dynamic>>[];
    clusterEnd = -1;
  }

  for (final it in items) {
    final s = _startMin(it);
    final e = s + _durMin(it);
    if (cluster.isEmpty || s < clusterEnd) {
      cluster.add(it);
      if (e > clusterEnd) clusterEnd = e;
    } else {
      flush();
      cluster.add(it);
      clusterEnd = e;
    }
  }
  flush();
  return out;
}

/// Day key for grouping; '' when the item has no usable date (inbox work).
String itemDateKey(Map<String, dynamic> item) {
  final w = parseWhen(item);
  if (w == null) return '';
  return dayKey(w);
}

String itemTimeLabel(Map<String, dynamic> item) {
  if (itemIsAllDay(item)) return 'All day';
  final w = parseWhen(item);
  if (w == null) return 'No time';
  return '${_two(w.hour)}:${_two(w.minute)}';
}

int _timeSortKey(Map<String, dynamic> item) {
  final w = parseWhen(item);
  if (w == null) return 24 * 60 + 1;
  return w.hour * 60 + w.minute;
}

/// All-day items first, then by start time, then by title.
List<Map<String, dynamic>> sortDayItems(List<Map<String, dynamic>> items) {
  final list = items.toList();
  list.sort((a, b) {
    final aAll = itemIsAllDay(a);
    final bAll = itemIsAllDay(b);
    if (aAll != bAll) return aAll ? -1 : 1;
    final ta = _timeSortKey(a);
    final tb = _timeSortKey(b);
    if (ta != tb) return ta.compareTo(tb);
    return itemTitle(a).compareTo(itemTitle(b));
  });
  return list;
}

Map<String, List<Map<String, dynamic>>> groupByDay(
    List<Map<String, dynamic>> items) {
  final map = <String, List<Map<String, dynamic>>>{};
  for (final it in items) {
    final k = itemDateKey(it);
    if (k.isEmpty) continue;
    map.putIfAbsent(k, () => <Map<String, dynamic>>[]).add(it);
  }
  return map;
}

class VectorCalendarApp extends StatelessWidget {
  const VectorCalendarApp({super.key});

  @override
  Widget build(BuildContext context) => CupertinoApp(
        title: 'Vector Calendar',
        debugShowCheckedModeBanner: false,
        theme: CupertinoThemeData(
            primaryColor: AppColors.accent,
            scaffoldBackgroundColor: AppColors.bgBase),
        // Clamp the system text scale. Android allows up to 200%, and the hour
        // gutter plus a long event title overflowed the right edge at that size.
        builder: (context, child) => MediaQuery.withClampedTextScaling(
          minScaleFactor: 0.8,
          maxScaleFactor: 1.2,
          child: child ?? const SizedBox.shrink(),
        ),
        home: CalendarPage(),
      );
}

/// One command-bar exchange, kept visible so the user sees what changed.

class CalendarPage extends StatefulWidget {
  const CalendarPage({super.key});

  @override
  State<CalendarPage> createState() => _CalendarPageState();
}

class _CalendarPageState extends State<CalendarPage> {
  // Plain fields with single assignment in initState/bootstrap.
  // (Deliberately NOT late final: a repeated load must never throw
  // LateInitializationError and strand the screen.)
  Api? _api;
  late DateTime _baseDate;
  late DateTime _selected;
  late DateTime _monthStart;
  PageController? _dayPager;

  static const int _pageCount = 731;
  static const int _basePage = 365;

  bool _loading = true;
  bool _loadingMonth = false;
  String? _error;
  String? _notice;
  Map<String, List<Map<String, dynamic>>> _byDay = {};
  Map<String, int> _dayCounts = {};
  List<Map<String, dynamic>> _inbox = [];

  final TextEditingController _cmd = TextEditingController();
  String? _cmdError;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _baseDate = dateOnly(now);
    _selected = dateOnly(now);
    _monthStart = DateTime(now.year, now.month, 1);
    _dayPager = PageController(initialPage: _basePage);
    Future.microtask(_bootstrap);
  }

  @override
  void dispose() {
    _cmd.dispose();
    _dayPager?.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    Api.beacon('calendar_start');
    String id = Api.defaultUserId;
    try {
      final prefs = await SharedPreferences.getInstance();
      id = prefs.getString('vector.user_id') ?? Api.defaultUserId;
    } catch (_) {
      // Prefs failure must not strand the app on a blank screen.
    }
    _api = Api(userId: id);
    await _loadMonth(_monthStart, spinner: true);
  }

  Future<void> _refresh() => _loadMonth(_monthStart);

  Future<void> _loadMonth(DateTime month, {bool spinner = false}) async {
    final api = _api;
    if (api == null) return;
    setState(() {
      if (spinner) {
        _loading = true;
      } else {
        _loadingMonth = true;
      }
      _error = null;
    });
    try {
      final first = DateTime(month.year, month.month, 1);
      final last = DateTime(month.year, month.month + 1, 0);
      final data = await api.calendarRange(
          start: dayKey(first), end: dayKey(last));
      if (!mounted) return;
      final items = Safe.mapList(data['items']);
      final days = Safe.mapList(data['days']);
      final grouped = groupByDay(items);
      final counts = <String, int>{};
      for (final d in days) {
        final k = (d['date'] ?? '').toString();
        if (k.isEmpty) continue;
        final c = Safe.number(d['count'])?.toInt() ?? 0;
        if (c > 0) counts[k] = c;
        // Some backends only nest items under days[]; merge those in so the
        // agenda and the dots agree.
        final nested = Safe.mapList(d['items']);
        for (final it in nested) {
          grouped.putIfAbsent(k, () => <Map<String, dynamic>>[]).add(it);
        }
      }
      // De-duplicate rows that arrived in both items[] and days[].items.
      for (final k in grouped.keys.toList()) {
        final cur = grouped[k];
        if (cur == null) continue;
        final seen = <String>{};
        final out = <Map<String, dynamic>>[];
        for (final it in cur) {
          final id = (it['id'] ?? '').toString();
          if (id.isNotEmpty) {
            if (seen.contains(id)) continue;
            seen.add(id);
          }
          out.add(it);
        }
        grouped[k] = out;
      }
      final inbox = <Map<String, dynamic>>[];
      for (final it in items) {
        if (itemDateKey(it).isEmpty) inbox.add(it);
      }
      setState(() {
        _byDay = grouped;
        _dayCounts = counts;
        _inbox = inbox;
        _loading = false;
        _loadingMonth = false;
        _notice = null;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
        _loadingMonth = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Something went wrong: $e';
        _loading = false;
        _loadingMonth = false;
      });
    }
  }

  /// Recent command history so the exchange stays visible across restarts.
  /// Best-effort: an unknown shape or a failure must never touch the calendar.

  int get _monthTotal {
    var n = 0;
    for (final l in _byDay.values) {
      n += l.length;
    }
    return n;
  }

  bool _hasDay(String k) {
    final items = _byDay[k];
    if (items != null && items.isNotEmpty) return true;
    return (_dayCounts[k] ?? 0) > 0;
  }

  // -- navigation ----------------------------------------------------------

  void _jumpPager(DateTime d) {
    final pager = _dayPager;
    if (pager == null || !pager.hasClients) return;
    final p = _basePage + d.difference(_baseDate).inDays;
    if (p < 0 || p >= _pageCount) return;
    pager.jumpToPage(p);
  }

  void _selectDay(DateTime d) {
    final day = dateOnly(d);
    final changedMonth =
        day.year != _monthStart.year || day.month != _monthStart.month;
    setState(() {
      _selected = day;
      if (changedMonth) {
        _monthStart = DateTime(day.year, day.month, 1);
      }
    });
    _jumpPager(day);
    // Same month: the grid already shows this month's data. New month:
    // fetch it so both the grid dots and the agenda agree.
    if (changedMonth) _loadMonth(_monthStart);
  }

  void _onDayPage(int i) {
    final d = addDays(_baseDate, i - _basePage);
    final changedMonth =
        d.year != _monthStart.year || d.month != _monthStart.month;
    setState(() {
      _selected = d;
      if (changedMonth) _monthStart = DateTime(d.year, d.month, 1);
    });
    if (changedMonth) _loadMonth(_monthStart);
  }

  void _goToday() {
    final now = dateOnly(DateTime.now());
    setState(() {
      _selected = now;
      _monthStart = DateTime(now.year, now.month, 1);
    });
    _jumpPager(now);
    _loadMonth(_monthStart);
  }

  void _stepMonth(int delta) {
    final m = DateTime(_monthStart.year, _monthStart.month + delta, 1);
    final dim = daysInMonth(m.year, m.month);
    final d = _selected.day > dim ? dim : _selected.day;
    final sel = DateTime(m.year, m.month, d);
    setState(() {
      _monthStart = m;
      _selected = sel;
    });
    _jumpPager(sel);
    _loadMonth(m);
  }

  // -- item actions --------------------------------------------------------

  Future<void> _toggleDone(Map<String, dynamic> item) async {
    final api = _api;
    final id = (item['id'] ?? '').toString();
    if (api == null || id.isEmpty) return;
    try {
      if (itemIsDone(item)) {
        await api.reopenTask(id);
      } else {
        await api.completeTask(id);
      }
      if (!mounted) return;
      await _loadMonth(_monthStart);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _notice = e.message);
    } catch (e) {
      if (!mounted) return;
      setState(() => _notice = 'Something went wrong: $e');
    }
  }

  Future<void> _confirmDelete(Map<String, dynamic> item) async {
    final api = _api;
    final id = (item['id'] ?? '').toString();
    if (api == null || id.isEmpty) return;
    final ok = await showCupertinoDialog<bool>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('Delete event?'),
        content: Text(itemTitle(item)),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await api.deleteTask(id);
      if (!mounted) return;
      await _loadMonth(_monthStart);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _notice = e.message);
    } catch (e) {
      if (!mounted) return;
      setState(() => _notice = 'Something went wrong: $e');
    }
  }

  void _itemActions(Map<String, dynamic> item) {
    final done = itemIsDone(item);
    showCupertinoModalPopup<void>(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        title: Text(itemTitle(item)),
        message: Text(itemTimeLabel(item)),
        actions: [
          CupertinoActionSheetAction(
            onPressed: () {
              Navigator.of(ctx).pop();
              _openEditor(existing: item);
            },
            child: const Text('Edit'),
          ),
          CupertinoActionSheetAction(
            onPressed: () {
              Navigator.of(ctx).pop();
              _toggleDone(item);
            },
            child: Text(done ? 'Mark not done' : 'Mark done'),
          ),
          CupertinoActionSheetAction(
            isDestructiveAction: true,
            onPressed: () {
              Navigator.of(ctx).pop();
              _confirmDelete(item);
            },
            child: const Text('Delete'),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Cancel'),
        ),
      ),
    );
  }

  Future<void> _openEditor(
      {Map<String, dynamic>? existing, DateTime? date}) async {
    final api = _api;
    if (api == null) return;
    final changed = await Navigator.of(context).push<bool>(
      CupertinoPageRoute<bool>(
        builder: (_) => _EventEditorPage(
          api: api,
          existing: existing,
          initialDate: date ?? _selected,
        ),
      ),
    );
    if (changed == true && mounted) {
      await _loadMonth(_monthStart);
    }
  }


  // -- build ---------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(
            '${monthName(_monthStart.month)} ${_monthStart.year}'),
        leading: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: _goToday,
          child: const Text('Today'),
        ),
        trailing: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: () => _openEditor(date: _selected),
          child: const Icon(CupertinoIcons.plus),
        ),
      ),
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [AppColors.bgTop, AppColors.bgBase],
          ),
        ),
        child: SafeArea(
          // Cupertino pull-to-refresh: CustomScrollView + slivers.
          child: CustomScrollView(
            slivers: [
              CupertinoSliverRefreshControl(onRefresh: _refresh),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
                sliver: SliverList(
                  delegate: SliverChildListDelegate(_buildBody()),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _buildBody() {
    if (_loading) {
      return const [
        SizedBox(height: 120),
        Center(child: CupertinoActivityIndicator(radius: 14)),
      ];
    }
    if (_error != null && _byDay.isEmpty && _inbox.isEmpty) {
      return [
        const SizedBox(height: 80),
        const Icon(CupertinoIcons.wifi_slash,
            size: 44, color: AppColors.textTertiary),
        const SizedBox(height: 14),
        Text(_error ?? 'Something went wrong',
            textAlign: TextAlign.center,
            style:
                const TextStyle(fontSize: 15, color: AppColors.textSecondary)),
        const SizedBox(height: 20),
        Center(
          child: CupertinoButton(
            onPressed: () => _loadMonth(_monthStart, spinner: true),
            child: const Text('Retry'),
          ),
        ),
      ];
    }

    final total = _monthTotal;
    return [
      const Text('Calendar',
          style: TextStyle(
              fontSize: 34,
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary)),
      const SizedBox(height: 4),
      Text(
          total == 0
              ? 'Nothing scheduled this month'
              : '$total ${total == 1 ? 'event' : 'events'} this month',
          style:
              const TextStyle(fontSize: 15, color: AppColors.textSecondary)),
      const SizedBox(height: 18),
      if (_notice != null) ...[
        _glass(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Text(_notice ?? '',
                style: const TextStyle(
                    fontSize: 13, color: AppColors.danger)),
          ),
        ),
        const SizedBox(height: 12),
      ],
      _monthCard(),
      const SizedBox(height: 16),
      _dayCard(),
      if (_inbox.isNotEmpty) ...[
        const SizedBox(height: 16),
        _inboxCard(),
      ],
      const SizedBox(height: 16),
    ];
  }

  // -- month grid ----------------------------------------------------------

  Widget _monthCard() {
    final year = _monthStart.year;
    final month = _monthStart.month;
    final first = DateTime(year, month, 1);
    final dim = daysInMonth(year, month);
    // Monday-first grid: leading blanks before the 1st.
    final leading = first.weekday - 1;
    final todayK = dayKey(DateTime.now());
    final selK = dayKey(_selected);

    final cells = <Widget>[];
    for (var i = 0; i < leading; i++) {
      cells.add(const Expanded(child: SizedBox(height: 44)));
    }
    for (var n = 1; n <= dim; n++) {
      final d = DateTime(year, month, n);
      final k = dayKey(d);
      final isToday = k == todayK;
      final isSel = k == selK;
      final busy = _hasDay(k);
      cells.add(Expanded(
        child: GestureDetector(
          onTap: () => _selectDay(d),
          behavior: HitTestBehavior.opaque,
          child: Container(
            height: 44,
            margin: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              color: isSel
                  // accentSoft at ~16% alpha, as a const (no runtime call).
                  ? const Color(0x298B5CF6)
                  : const Color(0x00000000),
              borderRadius: BorderRadius.circular(10),
              border: isSel
                  ? Border.all(color: AppColors.accent, width: 1.5)
                  : null,
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: isToday
                        ? AppColors.accent
                        : const Color(0x00000000),
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: Text('$n',
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight:
                              isToday ? FontWeight.w700 : FontWeight.w500,
                          color: isToday
                              ? CupertinoColors.white
                              : AppColors.textPrimary)),
                ),
                const SizedBox(height: 2),
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: busy
                        ? (isToday
                            ? AppColors.accent
                            : AppColors.accentSoft)
                        : const Color(0x00000000),
                    shape: BoxShape.circle,
                  ),
                ),
              ],
            ),
          ),
        ),
      ));
    }
    final trailing = (7 - ((leading + dim) % 7)) % 7;
    for (var i = 0; i < trailing; i++) {
      cells.add(const Expanded(child: SizedBox(height: 44)));
    }

    final rows = <Widget>[];
    const weekHead = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
    // Weekday header labels.
    rows.add(Row(
      children: [
        for (final w in weekHead)
          Expanded(
            child: Center(
              child: Text(w,
                  style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textTertiary)),
            ),
          ),
      ],
    ));
    rows.add(const SizedBox(height: 6));
    for (var i = 0; i < cells.length; i += 7) {
      final week = <Widget>[];
      for (var j = i; j < i + 7 && j < cells.length; j++) {
        week.add(cells[j]);
      }
      rows.add(Row(children: week));
    }

    return _glass(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          children: [
            Row(
              children: [
                CupertinoButton(
                  padding: EdgeInsets.zero,
                  onPressed: () => _stepMonth(-1),
                  child: const Icon(CupertinoIcons.chevron_left, size: 22),
                ),
                Expanded(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // Flexible + ellipsis: a long month name or a large text
                      // scale must shrink or ellipsise rather than push the
                      // chevrons off the edge, which is what "overflow to the
                      // right" looks like.
                      Flexible(
                        child: Text('${monthName(month)} $year',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w700,
                                color: AppColors.textPrimary)),
                      ),
                      if (_loadingMonth) ...[
                        const SizedBox(width: 8),
                        const CupertinoActivityIndicator(radius: 8),
                      ],
                    ],
                  ),
                ),
                CupertinoButton(
                  padding: EdgeInsets.zero,
                  onPressed: () => _stepMonth(1),
                  child: const Icon(CupertinoIcons.chevron_right, size: 22),
                ),
              ],
            ),
            const SizedBox(height: 6),
            ...rows,
          ],
        ),
      ),
    );
  }

  // -- day agenda (swipeable) ----------------------------------------------

  Widget _dayCard() {
    return _glass(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                      '${weekdayName(_selected.weekday)}, ${_selected.day} ${monthName(_selected.month)}',
                      // A long weekday plus a large system text scale would clip
                      // against the plus button; ellipsise instead of overflowing.
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                          color: AppColors.textPrimary)),
                ),
                CupertinoButton(
                  padding: EdgeInsets.zero,
                  onPressed: () => _openEditor(date: _selected),
                  child: const Icon(CupertinoIcons.plus, size: 22),
                ),
              ],
            ),
            const SizedBox(height: 4),
            const Text('Swipe sideways to move between days',
                style: TextStyle(
                    fontSize: 12, color: AppColors.textTertiary)),
            const SizedBox(height: 8),
            SizedBox(
              height: 380,
              child: PageView.builder(
                controller: _dayPager,
                itemCount: _pageCount,
                onPageChanged: _onDayPage,
                itemBuilder: (ctx, i) =>
                    _dayPage(addDays(_baseDate, i - _basePage)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _dayPage(DateTime d) {
    final k = dayKey(d);
    final raw = _byDay[k] ?? <Map<String, dynamic>>[];
    final items = sortDayItems(raw);
    // All-day and undated work is pinned above the grid: it has no hour, so
    // putting it in the grid would invent a time for it.
    final allDay = items
        .where((i) => itemIsAllDay(i) || parseWhen(i) == null)
        .toList();
    final timed = items
        .where((i) => !itemIsAllDay(i) && parseWhen(i) != null)
        .toList();

    final gridHeight = (kDayEndHour - kDayStartHour) * kHourHeight;
    final placed = layoutDay(timed);
    final isToday = dayKey(d) == dayKey(DateTime.now());

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (allDay.isNotEmpty) ...[
            _allDayStrip(allDay),
            const SizedBox(height: 10),
          ],
          SizedBox(
            height: gridHeight,
            child: Stack(
              children: [
                // The grid itself: one rule per hour, always drawn, so an empty
                // day still looks like a calendar rather than a blank page.
                Column(
                  children: [
                    for (var h = kDayStartHour; h < kDayEndHour; h++)
                      SizedBox(
                        height: kHourHeight,
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              width: 46,
                              child: Text(
                                '${_two(h)}:00',
                                style: const TextStyle(
                                    fontSize: 10,
                                    color: AppColors.textTertiary),
                              ),
                            ),
                            Expanded(
                              child: Container(
                                height: 1,
                                color: const Color(0x14000000),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
                // Item blocks, positioned by real time and sized by duration.
                for (final p in placed)
                  Positioned(
                    top: p.top(),
                    left: 50,
                    right: 0,
                    height: p.height() - 3,
                    child: FractionallySizedBox(
                      alignment: Alignment.centerLeft,
                      widthFactor: p.cols <= 1
                          ? 1.0
                          : (1.0 / p.cols) - (p.col == p.cols - 1 ? 0.0 : 0.02),
                      child: Padding(
                        padding: EdgeInsets.only(
                            left: p.cols <= 1
                                ? 0
                                : p.col * (1.0 / p.cols) * 0),
                        child: _gridBlock(p.item),
                      ),
                    ),
                  ),
                if (isToday) _nowLine(),
              ],
            ),
          ),
          if (items.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 22),
              child: Text('Nothing scheduled',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 15, color: AppColors.textSecondary)),
            ),
        ],
      ),
    );
  }

  /// A line at the current time, only on today.
  Widget _nowLine() {
    final now = DateTime.now();
    final m = now.hour * 60 + now.minute;
    if (m < kDayStartHour * 60 || m > kDayEndHour * 60) {
      return const SizedBox.shrink();
    }
    final top = (m - kDayStartHour * 60) / 60.0 * kHourHeight;
    return Positioned(
      top: top,
      left: 42,
      right: 0,
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: const BoxDecoration(
                shape: BoxShape.circle, color: AppColors.danger),
          ),
          Expanded(
            child: Container(height: 1.6, color: AppColors.danger),
          ),
        ],
      ),
    );
  }

  /// All-day and undated items, above the hour grid.
  Widget _allDayStrip(List<Map<String, dynamic>> items) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('ALL DAY',
            style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                color: AppColors.textTertiary,
                letterSpacing: 1.1)),
        const SizedBox(height: 6),
        for (final it in items) ...[
          _gridBlock(it, compact: true),
          const SizedBox(height: 6),
        ],
      ],
    );
  }

  /// One event block, drawn at its real position in the grid.
  Widget _gridBlock(Map<String, dynamic> item, {bool compact = false}) {
    final done = itemIsDone(item);
    final title = itemTitle(item);
    final mins = itemMinutes(item);
    final loc = (item['location'] ?? '').toString();
    final pri = Safe.number(item['priority'])?.toInt() ?? 3;
    final start = parseWhen(item);
    final end = start == null
        ? null
        : start.add(Duration(minutes: mins));
    final range = (start == null || itemIsAllDay(item))
        ? (compact ? 'All day' : '')
        : '${_two(start.hour)}:${_two(start.minute)}'
            '–${_two((end ?? start).hour)}:${_two((end ?? start).minute)}';
    final tint = done ? AppColors.textTertiary : _priColor(pri);

    return GestureDetector(
      onTap: () => _openEditor(existing: item),
      onLongPress: () => _itemActions(item),
      child: Container(
        decoration: BoxDecoration(
          color: done ? const Color(0x33FFFFFF) : const Color(0xE6FFFFFF),
          borderRadius: BorderRadius.circular(9),
          border: Border(left: BorderSide(color: tint, width: 3.5)),
        ),
        padding: const EdgeInsets.fromLTRB(8, 5, 8, 5),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.start,
          children: [
            Text(range,
                style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: tint)),
            Text(title.isEmpty ? '(no title)' : title,
                maxLines: compact ? 2 : 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: done
                        ? AppColors.textTertiary
                        : AppColors.textPrimary,
                    decoration: done
                        ? TextDecoration.lineThrough
                        : TextDecoration.none)),
            if (loc.isNotEmpty)
              Text(loc,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 10, color: AppColors.textSecondary)),
          ],
        ),
      ),
    );
  }

  Widget _agendaRow(Map<String, dynamic> item) {
    final done = itemIsDone(item);
    final title = itemTitle(item);
    final time = itemTimeLabel(item);
    final mins = itemMinutes(item);
    final loc = (item['location'] ?? '').toString();
    return GestureDetector(
      onTap: () => _openEditor(existing: item),
      onLongPress: () => _itemActions(item),
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xA6FFFFFF),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0x14000000)),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              GestureDetector(
                onTap: () => _toggleDone(item),
                child: Container(
                  width: 26,
                  height: 26,
                  margin: const EdgeInsets.only(top: 1),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: done
                        ? AppColors.success
                        : const Color(0x00000000),
                    border: Border.all(
                        color: done
                            ? AppColors.success
                            : AppColors.textTertiary,
                        width: 1.5),
                  ),
                  child: done
                      ? const Icon(CupertinoIcons.checkmark_alt,
                          size: 14, color: CupertinoColors.white)
                      : null,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title.isEmpty ? '(no title)' : title,
                        style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: done
                                ? AppColors.textTertiary
                                : AppColors.textPrimary,
                            decoration: done
                                ? TextDecoration.lineThrough
                                : TextDecoration.none)),
                    const SizedBox(height: 3),
                    Text('$time · $mins min',
                        style: const TextStyle(
                            fontSize: 13,
                            color: AppColors.textSecondary)),
                    if (loc.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(loc,
                          style: const TextStyle(
                              fontSize: 13,
                              color: AppColors.textSecondary)),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // -- inbox ---------------------------------------------------------------

  Widget _inboxCard() {
    return _glass(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Undated · ${_inbox.length}',
                style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1,
                    color: AppColors.textTertiary)),
            const SizedBox(height: 10),
            for (final it in _inbox) ...[
              _agendaRow(it),
              const SizedBox(height: 8),
            ],
          ],
        ),
      ),
    );
  }

  // -- command bar ----------------------------------------------------------


  // -- shared chrome ---------------------------------------------------------

  Widget _glass({required Widget child}) => Container(
        decoration: BoxDecoration(
          color: AppColors.glass,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0x14000000)),
          boxShadow: const [
            BoxShadow(
                color: Color(0x0D000000),
                blurRadius: 18,
                offset: Offset(0, 6)),
          ],
        ),
        child: child,
      );
}

// ---------------------------------------------------------------------------
// Create / edit page.
// ---------------------------------------------------------------------------

class _EventEditorPage extends StatefulWidget {
  const _EventEditorPage(
      {required this.api, this.existing, required this.initialDate});

  final Api api;
  final Map<String, dynamic>? existing;
  final DateTime initialDate;

  @override
  State<_EventEditorPage> createState() => _EventEditorPageState();
}

class _EventEditorPageState extends State<_EventEditorPage> {
  final TextEditingController _title = TextEditingController();
  final TextEditingController _minutes = TextEditingController();
  final TextEditingController _location = TextEditingController();
  final TextEditingController _notes = TextEditingController();

  String? _id;
  late DateTime _start;
  bool _allDay = false;
  bool _saving = false;
  bool _deleting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final ex = widget.existing;
    if (ex == null) {
      _start = DateTime(widget.initialDate.year, widget.initialDate.month,
          widget.initialDate.day, 9, 0);
      _minutes.text = '30';
    } else {
      _id = (ex['id'] ?? '').toString();
      if (_id != null && _id!.isEmpty) _id = null;
      _title.text = (ex['title'] ?? '').toString();
      _allDay = itemIsAllDay(ex);
      final w = parseWhen(ex);
      if (w == null) {
        _start = DateTime(widget.initialDate.year, widget.initialDate.month,
            widget.initialDate.day, 9, 0);
      } else {
        _start = w;
      }
      _minutes.text = '${itemMinutes(ex)}';
      _location.text = (ex['location'] ?? '').toString();
      _notes.text = (ex['notes'] ?? '').toString();
    }
  }

  @override
  void dispose() {
    _title.dispose();
    _minutes.dispose();
    _location.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final title = _title.text.trim();
    if (title.isEmpty) {
      setState(() => _error = 'Give the event a title.');
      return;
    }
    final parsed = int.tryParse(_minutes.text.trim());
    final mins = parsed == null || parsed <= 0 ? 30 : parsed;
    final loc = _location.text.trim();
    final notes = _notes.text.trim();
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final sched = _allDay
          ? '${dayKey(_start)}T00:00:00'
          : '${dayKey(_start)}T${_two(_start.hour)}:${_two(_start.minute)}:00';
      await widget.api.upsertTask(
        id: _id,
        title: title,
        scheduledAt: sched,
        minutes: mins,
        allDay: _allDay,
        location: loc.isEmpty ? null : loc,
        notes: notes.isEmpty ? null : notes,
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _saving = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Something went wrong: $e';
        _saving = false;
      });
    }
  }

  Future<void> _delete() async {
    final id = _id;
    if (id == null || id.isEmpty) return;
    final ok = await showCupertinoDialog<bool>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('Delete event?'),
        content: Text(_title.text.trim()),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() {
      _deleting = true;
      _error = null;
    });
    try {
      await widget.api.deleteTask(id);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _deleting = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Something went wrong: $e';
        _deleting = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final editing = _id != null;
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(editing ? 'Edit event' : 'New event'),
        leading: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        trailing: _saving
            ? const CupertinoActivityIndicator(radius: 9)
            : CupertinoButton(
                padding: EdgeInsets.zero,
                onPressed: _save,
                child: const Text('Save',
                    style: TextStyle(fontWeight: FontWeight.w600)),
              ),
      ),
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [AppColors.bgTop, AppColors.bgBase],
          ),
        ),
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Title',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 1,
                        color: AppColors.textTertiary)),
                const SizedBox(height: 6),
                CupertinoTextField(
                  controller: _title,
                  placeholder: 'Event title',
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    const Expanded(
                      child: Text('All-day',
                          style: TextStyle(
                              fontSize: 15,
                              color: AppColors.textPrimary)),
                    ),
                    CupertinoSwitch(
                      value: _allDay,
                      onChanged: (v) => setState(() => _allDay = v),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                const Text('Starts',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 1,
                        color: AppColors.textTertiary)),
                const SizedBox(height: 6),
                Container(
                  decoration: BoxDecoration(
                    color: AppColors.glass,
                    borderRadius: BorderRadius.circular(12),
                    border:
                        Border.all(color: const Color(0x14000000)),
                  ),
                  child: SizedBox(
                    height: 180,
                    child: CupertinoDatePicker(
                      mode: CupertinoDatePickerMode.dateAndTime,
                      initialDateTime: _start,
                      onDateTimeChanged: (d) =>
                          setState(() => _start = d),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                const Text('Duration (minutes)',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 1,
                        color: AppColors.textTertiary)),
                const SizedBox(height: 6),
                CupertinoTextField(
                  controller: _minutes,
                  placeholder: '30',
                  keyboardType: TextInputType.number,
                ),
                const SizedBox(height: 16),
                const Text('Location',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 1,
                        color: AppColors.textTertiary)),
                const SizedBox(height: 6),
                CupertinoTextField(
                  controller: _location,
                  placeholder: 'Where',
                ),
                const SizedBox(height: 16),
                const Text('Notes',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 1,
                        color: AppColors.textTertiary)),
                const SizedBox(height: 6),
                CupertinoTextField(
                  controller: _notes,
                  placeholder: 'Details',
                  maxLines: 3,
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error ?? '',
                      style: const TextStyle(
                          fontSize: 13, color: AppColors.danger)),
                ],
                if (editing) ...[
                  const SizedBox(height: 24),
                  Center(
                    child: _deleting
                        ? const CupertinoActivityIndicator(radius: 10)
                        : CupertinoButton(
                            onPressed: _delete,
                            child: const Text('Delete event',
                                style: TextStyle(
                                    color: AppColors.danger)),
                          ),
                  ),
                ],
                const SizedBox(height: 12),
                const Center(
                  child: Text(
                      'Tip: long-press an event for edit, done and delete.',
                      style: TextStyle(
                          fontSize: 12,
                          color: AppColors.textTertiary)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Shown instead of Flutter's default ErrorWidget when a widget's build throws.
///
/// In release builds that default is a blank grey box that prints nothing, so a
/// crash looks exactly like a hung request. This renders the message and stack
/// on screen, which is the only way a failure on a real device is reportable.
class _CrashReport extends StatelessWidget {
  const _CrashReport(this.details);

  final FlutterErrorDetails details;

  @override
  Widget build(BuildContext context) {
    final msg = details.exception.toString();
    final stack = details.stack?.toString() ?? '';
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Container(
        color: const Color(0xFF111827),
        padding: const EdgeInsets.all(14),
        child: SingleChildScrollView(
          child: Text(
            'VECTOR crashed\n\n$msg\n\n$stack',
            style: const TextStyle(color: Color(0xFFF9FAFB), fontSize: 11),
          ),
        ),
      ),
    );
  }
}
