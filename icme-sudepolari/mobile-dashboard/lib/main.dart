import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:syncfusion_flutter_gauges/gauges.dart';

class LowTankNotifier {
  LowTankNotifier._();

  static final LowTankNotifier instance = LowTankNotifier._();

  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;

  Future<void> init() async {
    if (_ready) return;

    const AndroidInitializationSettings androidInit =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const DarwinInitializationSettings iosInit = DarwinInitializationSettings();
    const InitializationSettings initSettings = InitializationSettings(
      android: androidInit,
      iOS: iosInit,
    );

    await _plugin.initialize(initSettings);

    const AndroidNotificationChannel channel = AndroidNotificationChannel(
      'low_tank_alerts',
      'Dusuk Depo Uyarilari',
      description: 'Depo seviyesi %33 ve altina dustugunde bildirim.',
      importance: Importance.high,
    );

    final AndroidFlutterLocalNotificationsPlugin? androidImplementation =
        _plugin.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    await androidImplementation?.createNotificationChannel(channel);

    if (defaultTargetPlatform == TargetPlatform.android) {
      await androidImplementation?.requestNotificationsPermission();
    } else if (defaultTargetPlatform == TargetPlatform.iOS) {
      await _plugin
          .resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()
          ?.requestPermissions(alert: true, badge: true, sound: true);
    }

    _ready = true;
  }

  int _notificationIdForTank(String tankName) => 9000 + (tankName.hashCode & 0x7fffffff) % 1000;

  Future<void> show({
    required String tankName,
    required int level,
  }) async {
    if (!_ready) await init();

    const AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
      'low_tank_alerts',
      'Dusuk Depo Uyarilari',
      channelDescription: 'Depo seviyesi %33 ve altina dustugunde bildirim.',
      importance: Importance.high,
      priority: Priority.high,
      ticker: 'tank',
    );
    const DarwinNotificationDetails iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );
    const NotificationDetails details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );

    await _plugin.show(
      _notificationIdForTank(tankName),
      'Dusuk depo: $tankName',
      'Seviye %$level (kritik esik: %33)',
      details,
    );
  }
}

/// Supabase `value` alani: JSON null, sayi veya (eski kayitlar icin) string olabilir.
int? _parseSensorJsonValue(dynamic raw) {
  if (raw == null) {
    return null;
  }
  if (raw is num) {
    return raw.round().clamp(0, 100);
  }
  return int.tryParse(raw.toString())?.clamp(0, 100);
}

/// PostgREST `created_at`: `...Z` veya `...+00:00` ise [DateTime.tryParse] dogru ani verir.
/// Offset yoksa Dart string'i **yerel saat** sanir; Supabase'te UTC tutulan `timestamptz` ~3s kayar (TR).
/// Naif string icin bileşenleri UTC kabul ederiz. Donus her zaman UTC (`isUtc: true`).
DateTime? _parseCreatedAtUtc(dynamic raw) {
  if (raw == null) {
    return null;
  }
  final String s = raw.toString().trim();
  if (s.isEmpty) {
    return null;
  }
  final DateTime? dt = DateTime.tryParse(s);
  if (dt == null) {
    return null;
  }
  final String t = s.trimRight();
  final bool hasExplicitTz = t.endsWith('Z') ||
      t.endsWith('z') ||
      RegExp(r'[+-]\d{2}:\d{2}$').hasMatch(t) ||
      RegExp(r'[+-]\d{2}\d{2}$').hasMatch(t);
  if (hasExplicitTz) {
    return dt.toUtc();
  }
  return DateTime.utc(
    dt.year,
    dt.month,
    dt.day,
    dt.hour,
    dt.minute,
    dt.second,
    dt.millisecond,
    dt.microsecond,
  );
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await LowTankNotifier.instance.init();
  runApp(const WaterTankDashboardApp());
}

class WaterTankDashboardApp extends StatelessWidget {
  const WaterTankDashboardApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Water Tank Dashboard',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
      ),
      home: const DashboardPage(),
    );
  }
}

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> with WidgetsBindingObserver {
  static const List<String> _defaultTankOrder = <String>[
    'YICME',
    'GEBAN',
    'TTOKI',
    'YTOKI',
    'AICME',
  ];
  static const String _tankOrderStorageKey = 'tank_order_v1';

  final List<String> _tankOrder = <String>[
    'YICME',
    'GEBAN',
    'TTOKI',
    'YTOKI',
    'AICME',
  ];

  final SupabaseSensorClient _client = const SupabaseSensorClient(
    endpoint:
        'https://ngdozrhycaeiabubrywf.supabase.co/rest/v1/sensor_data',
    apiKey: 'sb_publishable_DNrEyZFNk13VFNlfE2UhZg_FnVwiHcJ',
  );

  Map<String, TankReading> _latestReadings = <String, TankReading>{};
  final Map<String, int> _previousLevels = <String, int>{};
  final Set<String> _lowAlertSent = <String>{};
  bool _isLoading = true;
  bool _isFetching = false;
  String? _draggingTankName;
  String? _errorMessage;
  DateTime? _lastUpdate;
  Timer? _refreshTimer;
  static const Duration _foregroundPollInterval = Duration(seconds: 30);
  static const Duration _backgroundPollInterval = Duration(minutes: 1);
  String _appVersion = '';
  String _buildNumber = '';

  void _configurePollingTimer() {
    _refreshTimer?.cancel();

    final AppLifecycleState? state = WidgetsBinding.instance.lifecycleState;
    final bool isForeground = state == null || state == AppLifecycleState.resumed;
    final Duration interval =
        isForeground ? _foregroundPollInterval : _backgroundPollInterval;

    _refreshTimer = Timer.periodic(interval, (_) {
      _loadData(showLoader: false);
    });
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadSavedOrder();
    _loadData();
    _configurePollingTimer();
    _loadPackageInfo();
  }

  Future<void> _loadPackageInfo() async {
    try {
      final PackageInfo info = await PackageInfo.fromPlatform();
      if (!mounted) return;
      setState(() {
        _appVersion = info.version;
        _buildNumber = info.buildNumber;
      });
    } catch (_) {
      // Sessiz: build etiketi kritik degil
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _refreshTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _loadData(showLoader: false);
    }
    _configurePollingTimer();
  }

  bool _isBackgroundLifecycle() {
    final AppLifecycleState s = WidgetsBinding.instance.lifecycleState ??
        AppLifecycleState.resumed;
    return s == AppLifecycleState.paused || s == AppLifecycleState.detached;
  }

  Future<void> _maybeNotifyLowTanks(
    Map<String, TankReading> data,
    Map<String, int> previousLevels,
  ) async {
    if (!_isBackgroundLifecycle()) return;

    for (final MapEntry<String, TankReading> e in data.entries) {
      final String tank = e.key;
      final int? vRead = e.value.value;
      if (vRead == null) {
        continue;
      }
      final int v = vRead;
      final int? prev = previousLevels[tank];

      if (v > 33) {
        _lowAlertSent.remove(tank);
        continue;
      }

      final bool crossedIntoLow =
          prev == null || prev > 33;
      if (crossedIntoLow && !_lowAlertSent.contains(tank)) {
        _lowAlertSent.add(tank);
        await LowTankNotifier.instance.show(
          tankName: tank,
          level: v,
        );
      }
    }
  }

  Future<void> _loadSavedOrder() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final List<String>? saved = prefs.getStringList(_tankOrderStorageKey);
    if (saved == null || saved.isEmpty) return;

    final Set<String> allowed = _defaultTankOrder.toSet();
    final List<String> filtered = saved.where(allowed.contains).toList();
    for (final String tank in _defaultTankOrder) {
      if (!filtered.contains(tank)) {
        filtered.add(tank);
      }
    }
    if (filtered.length != _defaultTankOrder.length) return;

    if (!mounted) return;
    setState(() {
      _tankOrder
        ..clear()
        ..addAll(filtered);
    });
  }

  Future<void> _saveOrder() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_tankOrderStorageKey, _tankOrder);
  }

  Future<void> _loadData({bool showLoader = true}) async {
    if (_isFetching) {
      return;
    }
    final Map<String, int> previousLevelsSnapshot = Map<String, int>.from(_previousLevels);
    if (showLoader) {
      setState(() {
        _isLoading = true;
        _errorMessage = null;
      });
    }
    setState(() {
      _isFetching = true;
    });

    try {
      final Map<String, TankReading> data = await _client.fetchLatestByTank(
        _tankOrder,
      );
      if (!mounted) return;
      setState(() {
        _latestReadings = data;
        _lastUpdate = DateTime.now();
        _errorMessage = null;
        _isLoading = false;
        _isFetching = false;
      });
      await _maybeNotifyLowTanks(data, previousLevelsSnapshot);
      for (final MapEntry<String, TankReading> e in data.entries) {
        final int? v = e.value.value;
        if (v != null) {
          _previousLevels[e.key] = v;
        } else {
          _previousLevels.remove(e.key);
        }
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Veri alinirken hata olustu: $error';
        _isLoading = false;
        _isFetching = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF6F8FB),
      body: SafeArea(
        child: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoading && _latestReadings.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        const double horizontalPadding = 12;
        const double topPadding = 8;
        const double crossSpacing = 8;
        final bool hasError = _errorMessage != null;
        final double mw = constraints.maxWidth;
        final double mh = constraints.maxHeight;
        // Dar ekranda tek sutun; genislik arttikca iki sutun
        final int crossAxisCount = mw >= 340 ? 2 : 1;
        final double innerW = mw - horizontalPadding * 2;
        final double gapTotal = crossSpacing * (crossAxisCount > 1 ? crossAxisCount - 1 : 0);
        final double tileW = (innerW - gapTotal) / crossAxisCount;
        // Kart ic scale: dar hucrede yazi / kavanoz kuculur
        final double cardLayoutScale = (tileW / 168).clamp(0.72, 1.0);
        // childAspectRatio = gen / yuk — kisa ekranda daha "genis" (daha az yukseklik) hucre
        double aspectRatio = tileW / (crossAxisCount == 1 ? 200 : 188);
        if (mh < 620) {
          aspectRatio *= 1.12;
        }
        if (mh < 520) {
          aspectRatio *= 1.08;
        }
        aspectRatio = aspectRatio.clamp(0.82, 1.35);
        final double cardWidth = tileW;

        return RefreshIndicator(
          color: const Color(0xFF0288D1),
          onRefresh: () => _loadData(showLoader: false),
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: <Widget>[
              SliverToBoxAdapter(
                child: _buildHeaderPanel(
                  horizontalPadding: horizontalPadding,
                  topPadding: topPadding,
                ),
              ),
              if (hasError)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(
                      horizontalPadding,
                      0,
                      horizontalPadding,
                      6,
                    ),
                    child: Text(
                      _errorMessage!,
                      style: const TextStyle(color: Colors.red),
                    ),
                  ),
                ),
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: horizontalPadding),
                sliver: SliverGrid(
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: crossAxisCount,
                    crossAxisSpacing: crossAxisCount > 1 ? crossSpacing : 0,
                    mainAxisSpacing: 8,
                    childAspectRatio: aspectRatio,
                  ),
                  delegate: SliverChildBuilderDelegate(
                    (BuildContext context, int index) {
                      final String name = _tankOrder[index];
                      final TankReading? reading = _latestReadings[name];
                      final Widget card = _TankCard(
                        key: ValueKey<String>(name),
                        tankName: name,
                        level: reading?.value,
                        dataReceivedAt: reading?.createdAt,
                        compact: true,
                        layoutScale: cardLayoutScale,
                        onDoubleTap: () {
                          Navigator.of(context).push<void>(
                            MaterialPageRoute<void>(
                              builder: (BuildContext ctx) => TankWeeklyChartPage(
                                tankName: name,
                                client: _client,
                              ),
                            ),
                          );
                        },
                      );

                      return DragTarget<String>(
                        onWillAcceptWithDetails: (DragTargetDetails<String> details) =>
                            details.data != name,
                        onAcceptWithDetails: (DragTargetDetails<String> details) {
                          final String dragged = details.data;
                          final int from = _tankOrder.indexOf(dragged);
                          final int to = _tankOrder.indexOf(name);
                          if (from < 0 || to < 0 || from == to) return;
                          setState(() {
                            final String moved = _tankOrder.removeAt(from);
                            _tankOrder.insert(to, moved);
                            _draggingTankName = null;
                          });
                          _saveOrder();
                        },
                        builder: (
                          BuildContext context,
                          List<String?> candidateData,
                          List<dynamic> rejectedData,
                        ) {
                          return LongPressDraggable<String>(
                            data: name,
                            delay: const Duration(milliseconds: 220),
                            onDragStarted: () {
                              setState(() {
                                _draggingTankName = name;
                              });
                            },
                            onDragEnd: (_) {
                              if (!mounted) return;
                              setState(() {
                                _draggingTankName = null;
                              });
                            },
                            feedback: Material(
                              color: Colors.transparent,
                              child: SizedBox(
                                width: cardWidth,
                                child: Opacity(
                                  opacity: 0.94,
                                  child: _TankCard(
                                    tankName: name,
                                    level: reading?.value,
                                    dataReceivedAt: reading?.createdAt,
                                    compact: true,
                                    layoutScale: cardLayoutScale,
                                  ),
                                ),
                              ),
                            ),
                            childWhenDragging: Opacity(opacity: 0.35, child: card),
                            child: AnimatedScale(
                              scale: _draggingTankName == name ? 0.98 : 1,
                              duration: const Duration(milliseconds: 120),
                              child: card,
                            ),
                          );
                        },
                      );
                    },
                    childCount: _tankOrder.length,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildHeaderPanel({
    required double horizontalPadding,
    required double topPadding,
  }) {
    final String lastUpdateText = _lastUpdate == null
        ? 'Henuz veri yok'
        : 'Son guncelleme: ${_formatDateTime(_lastUpdate!)}';
    final TextScaler scaler = MediaQuery.textScalerOf(context);
    final double titleFs = scaler.scale(18).clamp(14, 22);
    final double subtitleFs = scaler.scale(15).clamp(12, 18);

    return Padding(
      padding: EdgeInsets.fromLTRB(horizontalPadding, topPadding, horizontalPadding, 10),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          gradient: const LinearGradient(
            colors: <Color>[Color(0xFF0D47A1), Color(0xFF1976D2)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: const Color(0xFF1976D2).withValues(alpha: 0.28),
              blurRadius: 14,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          'Icme Muhtarligi Su Depolari',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: titleFs,
                            fontWeight: FontWeight.w700,
                            height: 1.15,
                          ),
                        ),
                      ),
                      if (_buildNumber.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(left: 8, top: 1),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.18),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              _appVersion.isEmpty ? 'b$_buildNumber' : 'v$_appVersion ($_buildNumber)',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Takip Paneli',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: subtitleFs,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        const Icon(Icons.schedule_rounded, color: Colors.white, size: 16),
                        const SizedBox(width: 6),
                        Text(
                          lastUpdateText,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
          ],
        ),
      ),
    );
  }
}

class _TankCard extends StatelessWidget {
  const _TankCard({
    super.key,
    required this.tankName,
    required this.level,
    this.dataReceivedAt,
    this.compact = false,
    this.layoutScale = 1,
    this.onDoubleTap,
  });

  final String tankName;
  final int? level;
  final DateTime? dataReceivedAt;
  final bool compact;
  /// Hucre genisligine gore 0.72–1.0; yazilar ve kavanoz.
  final double layoutScale;
  final VoidCallback? onDoubleTap;

  @override
  Widget build(BuildContext context) {
    final TextScaler scaler = MediaQuery.textScalerOf(context);
    final double ls = layoutScale;
    final double pad = (14 * ls).clamp(8, 14);
    final double titleFs = scaler.scale((compact ? 15 : 17) * ls).clamp(11, 20);
    final double pctFs = scaler.scale((compact ? 18 : 28) * ls).clamp(14, 32);
    final double metaFs = scaler.scale((compact ? 10.5 : 11.5) * ls).clamp(9, 14);
    final double gaugeH = ((compact ? 86 : 170) * ls).clamp(56, 170);

    final bool noData = level == null;
    final int safeLevel = noData ? 0 : level!.clamp(0, 100);
    final Color barColor = noData ? const Color(0xFF78909C) : _colorForLevel(safeLevel);
    final IconData statusIcon = _iconForLevel(level);
    final Color accentColor = barColor;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onDoubleTap: onDoubleTap,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          gradient: LinearGradient(
            colors: <Color>[
              accentColor.withValues(alpha: 0.24),
              barColor.withValues(alpha: 0.18),
              Colors.white,
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: accentColor.withValues(alpha: 0.28),
              blurRadius: 16,
              offset: const Offset(0, 8),
            ),
          ],
          border: Border.all(color: accentColor.withValues(alpha: 0.55), width: 1.2),
        ),
        child: Padding(
          padding: EdgeInsets.all(pad),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Container(
                    width: ((compact ? 36 : 40) * ls).clamp(28, 44),
                    height: ((compact ? 36 : 40) * ls).clamp(28, 44),
                    decoration: BoxDecoration(
                      color: accentColor.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      statusIcon,
                      color: accentColor,
                      size: scaler.scale((compact ? 20 : 22) * ls).clamp(16, 24),
                    ),
                  ),
                  SizedBox(width: (compact ? 8 : 10) * ls),
                  Expanded(
                    child: Text(
                      tankName,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      softWrap: true,
                      style: TextStyle(
                        fontSize: titleFs,
                        fontWeight: FontWeight.w700,
                        height: 1.2,
                        letterSpacing: -0.2,
                        color: const Color(0xFF1A237E),
                      ),
                    ),
                  ),
                  SizedBox(
                    width: ((compact ? 34 : 38) * ls).clamp(28, 42),
                    child: Align(
                      alignment: Alignment.topCenter,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: barColor.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Padding(
                          padding: EdgeInsets.all((6 * ls).clamp(4, 8)),
                          child: Icon(
                            Icons.water_drop_rounded,
                            color: barColor,
                            size: scaler.scale((compact ? 17 : 18) * ls).clamp(14, 20),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              if (dataReceivedAt != null) ...<Widget>[
                SizedBox(height: (compact ? 4 : 6) * ls),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Padding(
                      padding: const EdgeInsets.only(top: 1),
                      child: Icon(
                        Icons.schedule_rounded,
                        size: metaFs + 1,
                        color: Colors.black45,
                      ),
                    ),
                    SizedBox(width: 5 * ls),
                    Expanded(
                      child: Text(
                        'Son kayit: ${_formatRelativeSensorAge(dataReceivedAt!)}',
                        style: TextStyle(
                          fontSize: metaFs,
                          height: 1.15,
                          color: Colors.black.withValues(alpha: 0.52),
                          fontWeight: FontWeight.w500,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ],
              SizedBox(height: (compact ? 8 : 12) * ls),
              SizedBox(
                height: gaugeH,
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Center(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            noData ? 'Veri yok' : '%$safeLevel',
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            style: TextStyle(
                              fontSize: pctFs,
                              fontWeight: FontWeight.bold,
                              height: 1,
                              color: noData ? Colors.blueGrey.shade700 : null,
                            ),
                          ),
                        ),
                      ),
                    ),
                    _WaterJarLinearGauge(
                      compact: compact,
                      layoutScale: ls,
                      level: level,
                      safeLevel: safeLevel,
                      barColor: barColor,
                      heightOverride: gaugeH,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WaterJarLinearGauge extends StatelessWidget {
  const _WaterJarLinearGauge({
    required this.compact,
    required this.layoutScale,
    required this.level,
    required this.safeLevel,
    required this.barColor,
    required this.heightOverride,
  });

  final bool compact;
  final double layoutScale;
  final int? level;
  final int safeLevel;
  final Color barColor;
  final double heightOverride;

  @override
  Widget build(BuildContext context) {
    final double ls = layoutScale;
    final double jarWidth = ((compact ? 60 : 76) * ls).clamp(44, 80);
    final double gaugeThickness = ((compact ? 24 : 30) * ls).clamp(18, 32);
    final double totalHeight = heightOverride;
    final double neckHeight = ((compact ? 5 : 6) * ls).clamp(3, 8);
    final double neckGap = (3 * ls).clamp(2, 4);
    final double baseGap = (4 * ls).clamp(2, 5);
    final double baseHeight = ((compact ? 7 : 8) * ls).clamp(5, 10);
    final double bodyHeight = math.max(
      32,
      totalHeight - neckHeight - neckGap - baseGap - baseHeight,
    );

    return SizedBox(
      width: jarWidth,
      height: totalHeight,
      child: Column(
        mainAxisSize: MainAxisSize.max,
        children: <Widget>[
          // Hafif "boyun" hissi
          Container(
            width: jarWidth * 0.52,
            height: neckHeight,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.45),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.55),
                width: 1.1,
              ),
            ),
          ),
          SizedBox(height: neckGap),
          SizedBox(
            height: bodyHeight,
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(22),
                gradient: LinearGradient(
                  colors: <Color>[
                    Colors.white.withValues(alpha: 0.62),
                    Colors.white.withValues(alpha: 0.14),
                  ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.72),
                  width: 1.8,
                ),
                boxShadow: <BoxShadow>[
                  BoxShadow(
                    color: barColor.withValues(alpha: 0.24),
                    blurRadius: 14,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: Stack(
                children: <Widget>[
                  Positioned.fill(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(7, 8, 7, 10),
                      child: LayoutBuilder(
                        builder: (BuildContext context, BoxConstraints _) {
                          final double fill =
                              level == null ? 0 : (safeLevel / 100).clamp(0, 1);

                          return Stack(
                            alignment: Alignment.center,
                            children: <Widget>[
                              Positioned.fill(
                                child: SfLinearGauge(
                                  minimum: 0,
                                  maximum: 100,
                                  orientation: LinearGaugeOrientation.vertical,
                                  isAxisInversed: false,
                                  showTicks: false,
                                  showLabels: false,
                                  axisTrackStyle: LinearAxisTrackStyle(
                                    thickness: gaugeThickness,
                                    edgeStyle: LinearEdgeStyle.bothCurve,
                                    color: Colors.grey.shade300,
                                  ),
                                  barPointers: <LinearBarPointer>[
                                    LinearBarPointer(
                                      value: level == null ? 0 : safeLevel.toDouble(),
                                      thickness: gaugeThickness,
                                      edgeStyle: LinearEdgeStyle.bothCurve,
                                      color: barColor,
                                      enableAnimation: false,
                                    ),
                                  ],
                                ),
                              ),
                              Positioned.fill(
                                child: CustomPaint(
                                  painter: _JarWavePainter(
                                    fillFraction: fill,
                                    phase: 0,
                                    waterColor: barColor,
                                  ),
                                ),
                              ),
                              // Cam parlama cizgisi
                              Positioned(
                                left: 7,
                                top: 10,
                                bottom: 12,
                                child: IgnorePointer(
                                  child: Container(
                                    width: 4,
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(999),
                                      gradient: LinearGradient(
                                        colors: <Color>[
                                          Colors.white.withValues(alpha: 0.55),
                                          Colors.white.withValues(alpha: 0.0),
                                        ],
                                        begin: Alignment.topCenter,
                                        end: Alignment.bottomCenter,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          SizedBox(height: baseGap),
          // Taban
          Container(
            width: jarWidth * 0.78,
            height: baseHeight,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.55),
                width: 1.1,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _JarWavePainter extends CustomPainter {
  _JarWavePainter({
    required this.fillFraction,
    required this.phase,
    required this.waterColor,
  });

  final double fillFraction;
  final double phase;
  final Color waterColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (fillFraction <= 0.001) return;

    final double h = size.height;
    final double w = size.width;
    final double surfaceY = h * (1 - fillFraction);

    final Path wavePath = Path()..moveTo(0, surfaceY);
    const int segments = 18;
    for (int i = 0; i <= segments; i++) {
      final double t = i / segments;
      final double x = t * w;
      final double wave =
          1.6 * (0.5 + 0.5 * (1 - fillFraction)) * math.sin((t * 2 * math.pi) + (phase * 2 * math.pi));
      wavePath.lineTo(x, surfaceY + wave);
    }
    wavePath.lineTo(w, h);
    wavePath.lineTo(0, h);
    wavePath.close();

    final Paint fillPaint = Paint()
      ..shader = LinearGradient(
        colors: <Color>[
          waterColor.withValues(alpha: 0.22),
          waterColor.withValues(alpha: 0.08),
        ],
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
      ).createShader(Rect.fromLTWH(0, surfaceY, w, h - surfaceY))
      ..style = PaintingStyle.fill;

    canvas.drawPath(wavePath, fillPaint);

    final Paint foam = Paint()
      ..color = Colors.white.withValues(alpha: 0.22)
      ..strokeWidth = 1.4
      ..style = PaintingStyle.stroke;
    canvas.drawPath(wavePath, foam);
  }

  @override
  bool shouldRepaint(covariant _JarWavePainter oldDelegate) {
    return oldDelegate.fillFraction != fillFraction ||
        oldDelegate.phase != phase ||
        oldDelegate.waterColor != waterColor;
  }
}

class TankReading {
  const TankReading({
    required this.name,
    required this.value,
    required this.createdAt,
  });

  final String name;
  /// Doluluk %%; Supabase `value` null ise veri gelmiyor (gateway stale heartbeat).
  final int? value;
  /// Supabase `created_at` anı (UTC).
  final DateTime createdAt;
}

class TankDailyPoint {
  const TankDailyPoint({
    required this.day,
    required this.value,
    required this.lastSeenAt,
  });

  final DateTime day;
  final int? value;
  final DateTime lastSeenAt;
}

class TankWeeklyChartPage extends StatefulWidget {
  const TankWeeklyChartPage({
    super.key,
    required this.tankName,
    required this.client,
  });

  final String tankName;
  final SupabaseSensorClient client;

  @override
  State<TankWeeklyChartPage> createState() => _TankWeeklyChartPageState();
}

class _TankWeeklyChartPageState extends State<TankWeeklyChartPage> {
  bool _loading = true;
  String? _error;
  List<TankDailyPoint> _points = <TankDailyPoint>[];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final List<TankDailyPoint> data =
          await widget.client.fetchLast7DaysDailyLatest(widget.tankName);
      if (!mounted) return;
      setState(() {
        _points = data;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF6F8FB),
      appBar: AppBar(
        title: Text('${widget.tankName} — Son 7 gun'),
      ),
      body: RefreshIndicator(
        color: const Color(0xFF0288D1),
        onRefresh: _load,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: MediaQuery.sizeOf(context).height -
                  kToolbarHeight -
                  MediaQuery.paddingOf(context).top,
            ),
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            _error!,
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Colors.red),
                          ),
                        ),
                      )
                    : _buildChart(),
          ),
        ),
      ),
    );
  }

  Widget _buildChart() {
    final List<FlSpot> spots = <FlSpot>[];
    for (int i = 0; i < _points.length; i++) {
      final int? v = _points[i].value;
      if (v != null) {
        spots.add(FlSpot(i.toDouble(), v.toDouble()));
      }
    }
    if (spots.length < 2) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'Grafik icin en az iki gunluk sayisal kayit gerekli '
            '(bazi gunlerde son kayit "veri yok" / null ise o gun cizilmez).',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyLarge,
          ),
        ),
      );
    }

    int? lastNumeric;
    for (int i = _points.length - 1; i >= 0; i--) {
      if (_points[i].value != null) {
        lastNumeric = _points[i].value;
        break;
      }
    }
    final Color lineColor = _colorForNullableLevel(lastNumeric);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'Her gun icin o gunun en son kaydi kullanilir.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          Expanded(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(18),
                boxShadow: <BoxShadow>[
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.06),
                    blurRadius: 12,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 16, 12, 8),
                child: LineChart(
                  LineChartData(
                    minY: 0,
                    maxY: 100,
                    gridData: FlGridData(
                      show: true,
                      drawVerticalLine: false,
                      horizontalInterval: 25,
                      getDrawingHorizontalLine: (double value) {
                        return FlLine(
                          color: Colors.grey.shade200,
                          strokeWidth: 1,
                        );
                      },
                    ),
                    titlesData: FlTitlesData(
                      topTitles: const AxisTitles(
                        sideTitles: SideTitles(showTitles: false),
                      ),
                      rightTitles: const AxisTitles(
                        sideTitles: SideTitles(showTitles: false),
                      ),
                      leftTitles: AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: true,
                          reservedSize: 36,
                          interval: 25,
                          getTitlesWidget: (double value, TitleMeta meta) {
                            return Text(
                              '${value.toInt()}',
                              style: TextStyle(
                                fontSize: 11,
                                color: Colors.grey.shade700,
                              ),
                            );
                          },
                        ),
                      ),
                      bottomTitles: AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: true,
                          reservedSize: 28,
                          interval: 1,
                          getTitlesWidget: (double value, TitleMeta meta) {
                            final int i = value.round();
                            if (i < 0 || i >= _points.length) {
                              return const SizedBox.shrink();
                            }
                            final DateTime d = _points[i].day;
                            final String dd = d.day.toString().padLeft(2, '0');
                            final String mm = d.month.toString().padLeft(2, '0');
                            return Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: Text(
                                '$dd/$mm',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Colors.grey.shade800,
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                    borderData: FlBorderData(show: false),
                    lineBarsData: <LineChartBarData>[
                      LineChartBarData(
                        spots: spots,
                        isCurved: true,
                        color: lineColor,
                        barWidth: 3,
                        dotData: FlDotData(
                          show: true,
                          getDotPainter: (FlSpot spot, double x, LineChartBarData bar, int index) {
                            return FlDotCirclePainter(
                              radius: 4,
                              color: lineColor,
                              strokeWidth: 2,
                              strokeColor: Colors.white,
                            );
                          },
                        ),
                        belowBarData: BarAreaData(
                          show: true,
                          gradient: LinearGradient(
                            colors: <Color>[
                              lineColor.withValues(alpha: 0.22),
                              lineColor.withValues(alpha: 0.02),
                            ],
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                          ),
                        ),
                      ),
                    ],
                  ),
                  duration: Duration.zero,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class SupabaseSensorClient {
  const SupabaseSensorClient({
    required this.endpoint,
    required this.apiKey,
    this.requestTimeout = const Duration(seconds: 10),
  });

  final String endpoint;
  final String apiKey;
  final Duration requestTimeout;

  Future<http.Response> _getWithTimeout(Uri uri) async {
    try {
      return await http
          .get(
            uri,
            headers: <String, String>{
              'apikey': apiKey,
              'Authorization': 'Bearer $apiKey',
            },
          )
          .timeout(requestTimeout);
    } on TimeoutException {
      throw Exception(
        'Supabase istegi zaman asimina ugradi (${requestTimeout.inSeconds}s): $uri',
      );
    }
  }

  Future<Map<String, TankReading>> fetchLatestByTank(
    List<String> tankNames,
  ) async {
    final List<TankReading?> rows = await Future.wait(
      tankNames.map(_fetchLatestSingleForTank),
    );

    final Map<String, TankReading> latest = <String, TankReading>{};
    for (int i = 0; i < tankNames.length; i++) {
      final TankReading? r = rows[i];
      if (r != null) {
        latest[r.name] = r;
      }
    }
    return latest;
  }

  /// Tek depo: `name=eq.<tank>` + en yeni satir (`limit=1`).
  Future<TankReading?> _fetchLatestSingleForTank(String tankName) async {
    final Uri base = Uri.parse(endpoint);
    final Uri uri = base.replace(
      queryParameters: <String, String>{
        'select': 'name,value,created_at',
        'name': 'eq.$tankName',
        'order': 'created_at.desc',
        'limit': '1',
      },
    );

    final http.Response response = await _getWithTimeout(uri);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
        'Supabase ($tankName) basarisiz: ${response.statusCode} ${response.body}',
      );
    }

    final dynamic decoded = jsonDecode(response.body);
    if (decoded is! List<dynamic>) {
      throw Exception('Beklenmeyen yanit formati ($tankName)');
    }
    if (decoded.isEmpty) {
      return null;
    }
    return _tankReadingFromRow(decoded.first);
  }

  TankReading? _tankReadingFromRow(dynamic raw) {
    if (raw is! Map<String, dynamic>) {
      return null;
    }
    final Map<String, dynamic> row = raw;
    final String? name = row['name']?.toString();
    if (name == null) {
      return null;
    }
    final int? value = _parseSensorJsonValue(row['value']);
    final DateTime? createdAt = _parseCreatedAtUtc(row['created_at']);
    if (createdAt == null) {
      return null;
    }
    return TankReading(
      name: name,
      value: value,
      createdAt: createdAt,
    );
  }

  /// Son 7 gun (bugun dahil) icin her gunun en son `value` degerini dondurur.
  Future<List<TankDailyPoint>> fetchLast7DaysDailyLatest(String tankName) async {
    final Uri base = Uri.parse(endpoint);
    final Uri uri = base.replace(
      queryParameters: <String, String>{
        'select': 'name,value,created_at',
        'name': 'eq.$tankName',
        'order': 'created_at.desc',
        'limit': '800',
      },
    );

    final http.Response response = await _getWithTimeout(uri);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
        'Supabase yaniti basarisiz: ${response.statusCode} ${response.body}',
      );
    }

    final dynamic decoded = jsonDecode(response.body);
    if (decoded is! List<dynamic>) {
      throw Exception('Beklenmeyen yanit formati');
    }

    final Map<String, TankDailyPoint> bestByDay = <String, TankDailyPoint>{};

    for (final dynamic row in decoded) {
      if (row is! Map<String, dynamic>) continue;
      final int? value = _parseSensorJsonValue(row['value']);
      final DateTime? createdAtUtc = _parseCreatedAtUtc(row['created_at']);
      if (createdAtUtc == null) {
        continue;
      }

      final DateTime local = createdAtUtc.toLocal();
      final DateTime day = DateTime(local.year, local.month, local.day);
      final String dayKey = '${day.year}-${day.month}-${day.day}';

      final TankDailyPoint? existing = bestByDay[dayKey];
      if (existing == null || local.isAfter(existing.lastSeenAt)) {
        bestByDay[dayKey] = TankDailyPoint(day: day, value: value, lastSeenAt: local);
      }
    }

    final DateTime today = DateTime.now();
    final DateTime todayDate = DateTime(today.year, today.month, today.day);
    final List<TankDailyPoint> series = <TankDailyPoint>[];
    int? carryValue;
    DateTime? carrySeen;

    for (int i = 6; i >= 0; i--) {
      final DateTime d = todayDate.subtract(Duration(days: i));
      final String key = '${d.year}-${d.month}-${d.day}';
      final TankDailyPoint? p = bestByDay[key];
      if (p != null) {
        if (p.value != null) {
          carryValue = p.value;
          carrySeen = p.lastSeenAt;
          series.add(TankDailyPoint(day: d, value: p.value, lastSeenAt: p.lastSeenAt));
        } else {
          carryValue = null;
          series.add(TankDailyPoint(day: d, value: null, lastSeenAt: p.lastSeenAt));
        }
      } else if (carryValue != null && carrySeen != null) {
        series.add(TankDailyPoint(day: d, value: carryValue, lastSeenAt: carrySeen));
      }
    }

    return series;
  }
}

String _formatDateTime(DateTime dateTime) {
  final String twoDigitMonth = dateTime.month.toString().padLeft(2, '0');
  final String twoDigitDay = dateTime.day.toString().padLeft(2, '0');
  final String twoDigitHour = dateTime.hour.toString().padLeft(2, '0');
  final String twoDigitMinute = dateTime.minute.toString().padLeft(2, '0');
  final String twoDigitSecond = dateTime.second.toString().padLeft(2, '0');
  return '$twoDigitDay.$twoDigitMonth.${dateTime.year} '
      '$twoDigitHour:$twoDigitMinute:$twoDigitSecond';
}

/// Depo karti: son kaydin ne kadar once geldigi (yaklasik; parent yenilenene kadar).
/// Karsilastirma UTC'de: cihaz / yaz saati farklari anlik suresi bozmaz.
String _formatRelativeSensorAge(DateTime receivedAt) {
  Duration diff = DateTime.now().toUtc().difference(receivedAt.toUtc());
  if (diff.isNegative) {
    diff = Duration.zero;
  }
  if (diff.inMinutes < 1) {
    return 'Az once';
  }
  if (diff.inHours < 1) {
    return '${diff.inMinutes} dk';
  }
  if (diff.inDays < 1) {
    final int h = diff.inHours;
    final int m = diff.inMinutes.remainder(60);
    if (m == 0) {
      return '$h sa';
    }
    return '$h sa $m dk';
  }
  final int days = diff.inDays;
  final int hRem = diff.inHours.remainder(24);
  if (days < 7) {
    if (hRem == 0) {
      return '$days gun';
    }
    return '$days gun $hRem sa';
  }
  final DateTime loc = receivedAt.toLocal();
  final String dd = loc.day.toString().padLeft(2, '0');
  final String mm = loc.month.toString().padLeft(2, '0');
  final String yy = (loc.year % 100).toString().padLeft(2, '0');
  final String hh = loc.hour.toString().padLeft(2, '0');
  final String mi = loc.minute.toString().padLeft(2, '0');
  return '$dd.$mm.$yy $hh:$mi';
}

Color _colorForLevel(int level) {
  // 100: koyu mavi, 66: acik mavi/turkuaz, 33: turuncu, 0: kirmizi
  if (level >= 84) return const Color(0xFF0D47A1);
  if (level >= 50) return const Color(0xFF00BCD4);
  if (level >= 17) return const Color(0xFFFF9800);
  return const Color(0xFFD50000);
}

Color _colorForNullableLevel(int? level) {
  if (level == null) {
    return const Color(0xFF78909C);
  }
  return _colorForLevel(level);
}

IconData _iconForLevel(int? level) {
  if (level == null) return Icons.water_drop_outlined;
  if (level >= 66) return Icons.check_circle_outline;
  if (level >= 33) return Icons.warning_amber_rounded;
  return Icons.error_outline;
}
