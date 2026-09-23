/// VECTOR Calendar — today's plan, in order.
///
/// Shows the day assembled from what is actually startable, plus what got done
/// and how much focus time was logged. Deliberately NOT a month grid: a month
/// view is another place to feel behind. The unit of work here is today.
library;

import 'package:flutter/cupertino.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_client.dart';

void main() {
  // In release builds a widget whose build() throws is replaced by a
  // blank ErrorWidget that prints nothing, so the screen just goes white
  // and the device reports no reason. Surface it instead.
  ErrorWidget.builder =
      (FlutterErrorDetails d) => _CrashReport(d);
  runApp(const VectorCalendarApp());
}

class C {
  static const bg = Color(0xFFF5F5F7);
  static const bgTop = Color(0xFFEEF1FF);
  static const glass = Color(0xCCFFFFFF);
  static const accent = Color(0xFF6366F1);
  static const success = Color(0xFF10B981);
  static const textPrimary = Color(0xFF1C1C1E);
  static const textSecondary = Color(0xFF6B7280);
  static const textTertiary = Color(0xFF9CA3AF);
}

class VectorCalendarApp extends StatelessWidget {
  const VectorCalendarApp({super.key});

  @override
  Widget build(BuildContext context) => const CupertinoApp(
        title: 'Vector Calendar',
        debugShowCheckedModeBanner: false,
        theme: CupertinoThemeData(
            primaryColor: C.accent, scaffoldBackgroundColor: C.bg),
        home: CalendarPage(),
      );
}

class CalendarPage extends StatefulWidget {
  const CalendarPage({super.key});

  @override
  State<CalendarPage> createState() => _CalendarPageState();
}

class _CalendarPageState extends State<CalendarPage> {
  Api? _api;
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _startable = [];
  List<Map<String, dynamic>> _done = [];
  int _focusMinutes = 0;

  @override
  void initState() {
    super.initState();
    Future.microtask(_bootstrap);
  }

  Future<void> _bootstrap() async {
    String id = Api.defaultUserId;
    try {
      final prefs = await SharedPreferences.getInstance();
      id = prefs.getString('vector.user_id') ?? Api.defaultUserId;
    } catch (_) {
      // Prefs failure must not strand the app on a blank screen.
    }
    _api = Api(userId: id);
    await _refresh();
  }

  Future<void> _refresh() async {
    final api = _api;
    if (api == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final t = await api.today();
      if (!mounted) return;
      setState(() {
        // `is` checks, not `as` casts: a wrong-typed value degrades to the
        // default instead of throwing inside setState and blanking the day.
        final rawStartable = t['startable'];
        _startable = rawStartable is List
            ? rawStartable
                .whereType<Map>()
                .map((m) => Map<String, dynamic>.from(m))
                .toList()
            : <Map<String, dynamic>>[];
        final rawDone = t['done_today'];
        _done = rawDone is List
            ? rawDone
                .whereType<Map>()
                .map((m) => Map<String, dynamic>.from(m))
                .toList()
            : <Map<String, dynamic>>[];
        _focusMinutes =
            t['focus_minutes'] is num ? (t['focus_minutes'] as num).toInt() : 0;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Something went wrong: $e';
        _loading = false;
      });
    }
  }

  int get _plannedMinutes => _startable.fold(
      0, (s, t) => s + (t['minutes'] is num ? (t['minutes'] as num).toInt() : 0));

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [C.bgTop, C.bg],
          ),
        ),
        child: SafeArea(
          // Cupertino pull-to-refresh: CustomScrollView + slivers.
          // RefreshIndicator is a Material widget and this app imports only
          // package:flutter/cupertino.dart, so it would not compile.
          child: CustomScrollView(
            slivers: [
              CupertinoSliverRefreshControl(onRefresh: _refresh),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 24, 20, 40),
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
    if (_error != null) {
      return [
        const SizedBox(height: 100),
        const Icon(CupertinoIcons.wifi_slash,
            size: 44, color: C.textTertiary),
        const SizedBox(height: 14),
        Text(_error!,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 15, color: C.textSecondary)),
        const SizedBox(height: 20),
        CupertinoButton(
          onPressed: _refresh,
          child: const Text('Retry'),
        ),
      ];
    }

    return [
      const Text('Today',
          style: TextStyle(
              fontSize: 34,
              fontWeight: FontWeight.w700,
              color: C.textPrimary)),
      const SizedBox(height: 4),
      Text(_todayLabel(),
          style: const TextStyle(fontSize: 15, color: C.textSecondary)),
      const SizedBox(height: 22),
      Row(children: [
        Expanded(
            child: _stat('${_startable.length}', 'to start', C.accent)),
        const SizedBox(width: 12),
        Expanded(
            child: _stat('$_plannedMinutes', 'minutes planned', C.accent)),
        const SizedBox(width: 12),
        Expanded(child: _stat('$_focusMinutes', 'focused', C.success)),
      ]),
      const SizedBox(height: 26),
      const Text('UP NEXT',
          style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 1,
              color: C.textTertiary)),
      const SizedBox(height: 10),
      if (_startable.isEmpty)
        _card(
          child: const Padding(
            padding: EdgeInsets.all(20),
            child: Text('Nothing startable right now.',
                style: TextStyle(fontSize: 15, color: C.textSecondary)),
          ),
        )
      else
        ..._startable.map(_taskRow),
      if (_done.isNotEmpty) ...[
        const SizedBox(height: 26),
        Text('DONE TODAY · ${_done.length}',
            style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                letterSpacing: 1,
                color: C.textTertiary)),
        const SizedBox(height: 10),
        ..._done.map((t) => _card(
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                child: Row(children: [
                  const Icon(CupertinoIcons.checkmark_alt,
                      size: 18, color: C.success),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(t['title']?.toString() ?? '',
                        style: const TextStyle(
                            fontSize: 15,
                            color: C.textSecondary,
                            decoration: TextDecoration.lineThrough)),
                  ),
                ]),
              ),
            )),
      ],
    ];
  }

  String _todayLabel() {
    const days = [
      'Monday', 'Tuesday', 'Wednesday', 'Thursday',
      'Friday', 'Saturday', 'Sunday',
    ];
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final n = DateTime.now();
    return '${days[n.weekday - 1]}, ${n.day} ${months[n.month - 1]}';
  }

  Widget _stat(String value, String label, Color color) => _card(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
          child: Column(children: [
            Text(value,
                style: TextStyle(
                    fontSize: 22, fontWeight: FontWeight.w700, color: color)),
            const SizedBox(height: 3),
            Text(label,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 11, color: C.textSecondary)),
          ]),
        ),
      );

  Widget _taskRow(Map<String, dynamic> t) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: _card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(children: [
              Container(
                width: 4,
                height: 40,
                decoration: BoxDecoration(
                  color: C.accent,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(t['title']?.toString() ?? '',
                        style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w500,
                            color: C.textPrimary)),
                    if ((t['why'] ?? '').toString().isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(t['why'].toString(),
                          style: const TextStyle(
                              fontSize: 12, color: C.textTertiary)),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Text('${t['minutes']}m',
                  style: const TextStyle(
                      fontSize: 13, color: C.textSecondary)),
            ]),
          ),
        ),
      );

  Widget _card({required Widget child}) => Container(
        decoration: BoxDecoration(
          color: C.glass,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0x14000000)),
          boxShadow: const [
            BoxShadow(
                color: Color(0x0D000000), blurRadius: 18, offset: Offset(0, 6)),
          ],
        ),
        child: child,
      );
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
