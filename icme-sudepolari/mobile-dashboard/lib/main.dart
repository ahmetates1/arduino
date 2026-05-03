import 'dart:async';
import 'dart:convert';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Ham `Exception` / JSON govdesi yerine kullaniciya gosterilecek mesaj.
String _formatSensorFetchError(Object error) {
  final String raw = error.toString();

  if (error is TimeoutException ||
      raw.contains('TimeoutException') ||
      raw.contains('zaman asim')) {
    return 'Sunucuya zamaninda ulasilamadi. Baglantiyi kontrol edip tekrar deneyin.';
  }
  if (raw.contains('SocketException') ||
      raw.contains('Failed host lookup') ||
      raw.contains('Network is unreachable') ||
      raw.contains('Connection refused')) {
    return 'Internet baglantisi yok veya sunucuya ulasilamiyor.';
  }
  if (raw.contains('HandshakeException') ||
      raw.contains('CERTIFICATE_VERIFY_FAILED')) {
    return 'Guvenli baglanti kurulamadi.';
  }
  if (raw.contains('ClientException')) {
    return 'Ag istegi tamamlanamadi. Baglantiyi kontrol edin.';
  }
  if (error is FormatException || raw.contains('FormatException')) {
    return 'Sunucu yaniti beklenen formatta degil.';
  }

  final RegExp codeRx = RegExp(r'\b(\d{3})\b');
  final Match? m = codeRx.firstMatch(raw);
  if (m != null) {
    final int code = int.parse(m.group(1)!);
    if (code == 401 || code == 403) {
      return 'Veritabanina erisim reddedildi (yetki). Yonetici ile iletisime gecin.';
    }
    if (code == 404) {
      return 'Istenen kaynak bulunamadi.';
    }
    if (code >= 500 && code < 600) {
      return 'Sunucu gecici olarak yanit veremiyor. Bir sure sonra yenileyin.';
    }
    if (code >= 400 && code < 500) {
      return 'Istek kabul edilmedi (kod $code).';
    }
  }

  return 'Veri alinamadi. Asagi cekerek yenileyin veya baglantinizi kontrol edin.';
}

void _debugLogFetchFailure(String context, Object error) {
  if (kDebugMode) {
    debugPrint('[$context] $error');
  }
}

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

/// REST yanitindaki satirin `name` alani istenen depo ile eslesiyor mu (trim; ASCII icin buyuk/kucuk harf yok sayilir).
bool _sensorRowMatchesTank(Map<String, dynamic> row, String tankName) {
  final Object? raw = row['name'];
  if (raw == null) {
    return false;
  }
  final String a = raw.toString().trim();
  final String b = tankName.trim();
  if (a.isEmpty || b.isEmpty) {
    return false;
  }
  return a.toUpperCase() == b.toUpperCase();
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
    _bootstrapDashboard();
    _configurePollingTimer();
    _loadPackageInfo();
  }

  /// Kayitli depo sirasi yuklendikten sonra ilk cekimi yapar (acilista siralar / veriler karismasin).
  Future<void> _bootstrapDashboard() async {
    await _loadSavedOrder();
    if (!mounted) {
      return;
    }
    await _loadData();
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
      _debugLogFetchFailure('Dashboard.fetch', error);
      if (!mounted) return;
      setState(() {
        _errorMessage = _formatSensorFetchError(error);
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
        const double listGap = 6;
        final bool hasError = _errorMessage != null;
        final double mw = constraints.maxWidth;
        final double innerW = mw - horizontalPadding * 2;
        // Her depo tam genislik tek satir; mockup tarzi yatay kart
        final double cardLayoutScale = (innerW / 300).clamp(0.88, 1.12);
        final bool cardCompact = mw < 340;

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
                      8,
                    ),
                    child: Material(
                      color: Colors.red.shade50,
                      borderRadius: BorderRadius.circular(12),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Icon(
                              Icons.cloud_off_rounded,
                              color: Colors.red.shade800,
                              size: 22,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                _errorMessage!,
                                style: TextStyle(
                                  color: Colors.red.shade900,
                                  height: 1.35,
                                  fontSize: 13.5,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: horizontalPadding),
                sliver: SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (BuildContext context, int index) {
                      final String name = _tankOrder[index];
                      final TankReading? reading = _latestReadings[name];
                      final Widget card = _TankCard(
                        key: ValueKey<String>(name),
                        tankName: name,
                        level: reading?.value,
                        dataReceivedAt: reading?.createdAt,
                        compact: cardCompact,
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

                      return Padding(
                        padding: EdgeInsets.only(
                          bottom: index < _tankOrder.length - 1 ? listGap : 0,
                        ),
                        child: DragTarget<String>(
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
                                  width: innerW,
                                  child: Opacity(
                                    opacity: 0.94,
                                    child: _TankCard(
                                      tankName: name,
                                      level: reading?.value,
                                      dataReceivedAt: reading?.createdAt,
                                      compact: cardCompact,
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
                        ),
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
        : 'Son guncelleme: ${_formatRelativeSensorAge(_lastUpdate!)}';
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

/// Depo durumu: mockup tarzi `[OK]` etiketi + sag buyuk ikon (veri Supabase doluluk).
({String badge, IconData icon}) _tankUiStatus(int? level) {
  if (level == null) {
    return (badge: 'VERİ YOK', icon: Icons.cloud_off_rounded);
  }
  final int v = level.clamp(0, 100);
  if (v >= 34) {
    return (badge: 'OK', icon: Icons.water_drop_rounded);
  }
  if (v >= 1) {
    return (badge: 'KRİTİK UYARI', icon: Icons.warning_amber_rounded);
  }
  return (badge: 'ACİL', icon: Icons.emergency_rounded);
}

String _compactBracketBadge(String badge, bool compact) {
  if (!compact) {
    return badge;
  }
  if (badge == 'KRİTİK UYARI') {
    return 'KRİTİK';
  }
  return badge;
}

class _BracketStatusBadge extends StatelessWidget {
  const _BracketStatusBadge({
    required this.label,
    required this.accent,
    required this.compact,
    required this.scaler,
  });

  final String label;
  final Color accent;
  final bool compact;
  final TextScaler scaler;

  @override
  Widget build(BuildContext context) {
    final double fs = scaler.scale((compact ? 10 : 11)).clamp(9, 13);
    return Container(
      constraints: BoxConstraints(maxWidth: compact ? 104 : 168),
      padding: EdgeInsets.symmetric(
        horizontal: (compact ? 7 : 9),
        vertical: 4,
      ),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: accent.withValues(alpha: 0.38)),
      ),
      child: Text(
        '[$label]',
        textAlign: TextAlign.center,
        style: TextStyle(
          color: accent,
          fontWeight: FontWeight.w800,
          fontSize: fs,
          height: 1.15,
        ),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
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
    final double pad = (10 * ls).clamp(7, 13);
    final double titleFs = scaler.scale((compact ? 15 : 17) * ls).clamp(13, 20);
    final double overlayPctFs =
        scaler.scale((compact ? 17.5 : 21.5) * ls).clamp(14, 26);
    // Son kayit: %%'den her zaman kucuk, ama onceki sabit metadan daha buyuk
    final double metaFs =
        (overlayPctFs * 0.91).clamp(12.5, overlayPctFs - 0.5);
    final double bandH = scaler.scale((compact ? 52 : 58) * ls).clamp(46.0, 72.0);

    final bool noData = level == null;
    final int safeLevel = noData ? 0 : level!.clamp(0, 100);
    final Color barColor =
        noData ? const Color(0xFF6C757D) : _colorForLevel(safeLevel);
    final Color vivid =
        noData ? const Color(0xFF6C757D) : _gaugeChromaBoost(barColor);

    final ({String badge, IconData icon}) status = _tankUiStatus(level);
    final String badgeLabel = _compactBracketBadge(status.badge, compact);

    final Color titleColor =
        noData ? const Color(0xFF546E7A) : const Color(0xFF102027);

    final double iconCol =
        scaler.scale((compact ? 36 : 44) * ls).clamp(32, 52);
    final double iconSize =
        scaler.scale((compact ? 28 : 34) * ls).clamp(24, 44);

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onDoubleTap: onDoubleTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: Stack(
          clipBehavior: Clip.hardEdge,
          children: <Widget>[
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: <Color>[
                      Colors.white,
                      Color.lerp(Colors.white, Colors.blueGrey.shade50, 0.65)!,
                    ],
                  ),
                  border: Border.all(color: Colors.grey.shade300),
                  boxShadow: <BoxShadow>[
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.07),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                      spreadRadius: 0,
                    ),
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.045),
                      blurRadius: 22,
                      offset: const Offset(0, 10),
                    ),
                    // Alt kenarda hafif derinlik (ince golge cizgisi)
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.065),
                      blurRadius: 8,
                      offset: const Offset(0, 5),
                      spreadRadius: -3,
                    ),
                    if (!noData)
                      BoxShadow(
                        color: vivid.withValues(alpha: 0.16),
                        blurRadius: 28,
                        offset: const Offset(0, 10),
                        spreadRadius: -4,
                      ),
                  ],
                ),
              ),
            ),
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: 4,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: <Color>[
                      vivid.withValues(alpha: noData ? 0.35 : 0.5),
                      vivid.withValues(alpha: noData ? 0.15 : 0.28),
                    ],
                  ),
                ),
              ),
            ),
            Positioned(
              right: 0,
              top: 0,
              bottom: 0,
              width: 5,
              child: DecoratedBox(
                decoration: BoxDecoration(color: vivid),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: 18,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: const BorderRadius.vertical(
                      bottom: Radius.circular(18),
                    ),
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: <Color>[
                        Colors.transparent,
                        Colors.black.withValues(alpha: 0.045),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(pad + 5, pad, pad + 10, pad),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          tankName,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          softWrap: true,
                          style: TextStyle(
                            fontSize: titleFs,
                            fontWeight: FontWeight.w800,
                            height: 1.15,
                            letterSpacing: -0.35,
                            color: titleColor,
                          ),
                        ),
                      ),
                      SizedBox(width: 8 * ls),
                      _BracketStatusBadge(
                        label: badgeLabel,
                        accent: vivid,
                        compact: compact,
                        scaler: scaler,
                      ),
                    ],
                  ),
                  SizedBox(height: (compact ? 8 : 10) * ls),
                  SizedBox(
                    height: bandH,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        _WaterTankIllustration(
                          safeLevel: safeLevel,
                          barColor: barColor,
                          vivid: vivid,
                          noData: noData,
                        ),
                        SizedBox(width: (compact ? 8 : 12) * ls),
                        Expanded(
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: <Widget>[
                                if (noData)
                                  Text(
                                    'Veri yok',
                                    style: TextStyle(
                                      fontSize: scaler
                                          .scale((compact ? 11.5 : 12.5) * ls)
                                          .clamp(10, 14),
                                      fontWeight: FontWeight.w600,
                                      color: const Color(0xFF6C757D),
                                    ),
                                  )
                                else
                                  FittedBox(
                                    fit: BoxFit.scaleDown,
                                    alignment: Alignment.centerLeft,
                                    child: Text(
                                      '%$safeLevel',
                                      style: TextStyle(
                                        fontSize: overlayPctFs,
                                        fontWeight: FontWeight.w600,
                                        height: 1.05,
                                        letterSpacing: -0.15,
                                        color: Color.lerp(
                                          barColor,
                                          const Color(0xFF37474F),
                                          0.22,
                                        )!,
                                      ),
                                    ),
                                  ),
                                SizedBox(width: (compact ? 8 : 10) * ls),
                                Icon(
                                  Icons.schedule_rounded,
                                  size: scaler
                                      .scale((compact ? 13 : 14) * ls)
                                      .clamp(12, 17),
                                  color: Colors.grey.shade600,
                                ),
                                SizedBox(width: 4 * ls),
                                Expanded(
                                  child: Text(
                                    dataReceivedAt == null
                                        ? 'bekleniyor'
                                        : _formatRelativeSensorAge(
                                            dataReceivedAt!,
                                          ),
                                    style: TextStyle(
                                      fontSize: metaFs,
                                      height: 1.2,
                                      color: noData
                                          ? Colors.blueGrey.shade600
                                          : Colors.grey.shade800,
                                      fontWeight: FontWeight.w600,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        SizedBox(width: (compact ? 4 : 8) * ls),
                        SizedBox(
                          width: iconCol,
                          child: Center(
                            child: Icon(
                              status.icon,
                              color: vivid,
                              size: iconSize,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Ince mockup deposu (yalnizca silindir cizimi; %% ve son kayit ust kartta).
class _WaterTankIllustration extends StatelessWidget {
  const _WaterTankIllustration({
    required this.safeLevel,
    required this.barColor,
    required this.vivid,
    required this.noData,
  });

  final int safeLevel;
  final Color barColor;
  final Color vivid;
  final bool noData;

  @override
  Widget build(BuildContext context) {
    final double fillT =
        noData ? 0.0 : (safeLevel / 100.0).clamp(0.0, 1.0);

    final Color lt = noData
        ? const Color(0xFFCFD8DC)
        : Color.lerp(barColor, Colors.white, 0.2)!;
    final Color lm = noData ? const Color(0xFFB0BEC5) : barColor;
    final Color lb = noData
        ? const Color(0xFF90A4AE)
        : Color.lerp(barColor, const Color(0xFF050505), 0.26)!;

    final Color strokeCol =
        noData ? Colors.blueGrey.shade400 : vivid.withValues(alpha: 0.88);
    final Color chamberBg = noData
        ? const Color(0xFFECEFF1)
        : Color.lerp(const Color(0xFFE8F4FC), barColor, 0.14)!;

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double maxH = constraints.hasBoundedHeight && constraints.maxHeight > 8
            ? constraints.maxHeight
            : 96.0;
        final double tankW = (maxH * 0.30).clamp(34.0, 52.0);

        return SizedBox(
          width: tankW,
          height: maxH,
          child: CustomPaint(
            painter: _WaterTankPainter(
              fillFraction: fillT,
              liquidTop: lt,
              liquidMid: lm,
              liquidBot: lb,
              noData: noData,
              strokeColor: strokeCol,
              chamberBg: chamberBg,
            ),
          ),
        );
      },
    );
  }
}

class _WaterTankPainter extends CustomPainter {
  _WaterTankPainter({
    required this.fillFraction,
    required this.liquidTop,
    required this.liquidMid,
    required this.liquidBot,
    required this.noData,
    required this.strokeColor,
    required this.chamberBg,
  });

  final double fillFraction;
  final Color liquidTop;
  final Color liquidMid;
  final Color liquidBot;
  final bool noData;
  final Color strokeColor;
  final Color chamberBg;

  @override
  void paint(Canvas canvas, Size size) {
    final double w = size.width;
    final double h = size.height;
    // Ince sutunda govdeyi kanali dolduracak sekilde (mockup silindir).
    final double tw = w * 0.88;
    final double left = (w - tw) / 2;
    final double top = h * 0.06;
    final double bottom = h * 0.94;

    final double filletTop = (tw * 0.42).clamp(12.0, 26.0);
    final double filletBot = (tw * 0.17).clamp(6.0, 13.0);
    final RRect outer = RRect.fromLTRBAndCorners(
      left,
      top,
      left + tw,
      bottom,
      topLeft: Radius.circular(filletTop),
      topRight: Radius.circular(filletTop),
      bottomLeft: Radius.circular(filletBot),
      bottomRight: Radius.circular(filletBot),
    );

    final RRect inner = outer.deflate(w < 46 ? 3.5 : 4.5);

    canvas.drawRRect(
      outer,
      Paint()
        ..shader = LinearGradient(
          colors: <Color>[
            strokeColor.withValues(alpha: noData ? 0.35 : 0.52),
            strokeColor.withValues(alpha: noData ? 0.12 : 0.22),
          ],
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
        ).createShader(outer.outerRect),
    );

    canvas.drawRRect(inner, Paint()..color = chamberBg);

    if (!noData && fillFraction > 0.008) {
      canvas.save();
      canvas.clipRRect(inner);
      final double surfY = inner.bottom - inner.height * fillFraction;
      final Rect liq = Rect.fromLTRB(
        inner.left,
        surfY,
        inner.right,
        inner.bottom,
      );
      canvas.drawRect(
        liq,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: <Color>[liquidTop, liquidMid, liquidBot],
            stops: const <double>[0.0, 0.45, 1.0],
          ).createShader(liq),
      );
      canvas.drawLine(
        Offset(inner.left, surfY),
        Offset(inner.right, surfY),
        Paint()
          ..color = Colors.white.withValues(alpha: 0.65)
          ..strokeWidth = 2,
      );
      canvas.restore();
    }

    // Gosterge cizgileri (ic)
    final Paint grid = Paint()
      ..color = Colors.black.withValues(alpha: noData ? 0.06 : 0.1)
      ..strokeWidth = 1;
    for (int i = 1; i < 4; i++) {
      final double y = inner.top + inner.height * i / 4;
      canvas.drawLine(
        Offset(inner.left + 3, y),
        Offset(inner.right - 3, y),
        grid,
      );
    }

    canvas.drawRRect(
      inner,
      Paint()
        ..color = strokeColor.withValues(alpha: noData ? 0.55 : 0.85)
        ..style = PaintingStyle.stroke
        ..strokeWidth = noData ? 1.8 : 2.2,
    );

    final double footW = tw * 0.14;
    final double fh = h * 0.035;
    final Paint foot = Paint()
      ..color = strokeColor.withValues(alpha: 0.55)
      ..style = PaintingStyle.fill;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTRB(left + tw * 0.18, bottom, left + tw * 0.18 + footW, bottom + fh),
        Radius.circular(3),
      ),
      foot,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTRB(left + tw * 0.68, bottom, left + tw * 0.68 + footW, bottom + fh),
        Radius.circular(3),
      ),
      foot,
    );
  }

  @override
  bool shouldRepaint(covariant _WaterTankPainter oldDelegate) {
    return oldDelegate.fillFraction != fillFraction ||
        oldDelegate.noData != noData ||
        oldDelegate.liquidTop != liquidTop ||
        oldDelegate.liquidMid != liquidMid ||
        oldDelegate.liquidBot != liquidBot ||
        oldDelegate.strokeColor != strokeColor ||
        oldDelegate.chamberBg != chamberBg;
  }
}

/// Depo göstergesinde [barColor] tonunu hafifçe canlandırır; eşik renklerini birbirine yakınsatmaz.
Color _gaugeChromaBoost(Color c) {
  final HSVColor h = HSVColor.fromColor(c);
  final double s = (h.saturation * 1.08 + 0.02).clamp(0.0, 1.0);
  final double v = (h.value * 1.03).clamp(0.0, 1.0);
  return HSVColor.fromAHSV(c.a, h.hue, s, v).toColor();
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
      _debugLogFetchFailure('Chart7d.${widget.tankName}', e);
      if (!mounted) return;
      setState(() {
        _error = _formatSensorFetchError(e);
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
                          child: Material(
                            color: Colors.red.shade50,
                            borderRadius: BorderRadius.circular(12),
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: <Widget>[
                                  Icon(
                                    Icons.cloud_off_rounded,
                                    color: Colors.red.shade800,
                                    size: 40,
                                  ),
                                  const SizedBox(height: 12),
                                  Text(
                                    _error!,
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: Colors.red.shade900,
                                      height: 1.4,
                                      fontSize: 14,
                                    ),
                                  ),
                                ],
                              ),
                            ),
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
      throw TimeoutException(
        'Supabase istegi zaman asimina ugradi (${requestTimeout.inSeconds}s)',
        requestTimeout,
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
        latest[tankNames[i]] = TankReading(
          name: tankNames[i],
          value: r.value,
          createdAt: r.createdAt,
        );
      }
    }
    return latest;
  }

  /// En yeni satir `value=null` (stale) olsa bile, son sayisal doluluk varsa onu gosterir.
  /// Tek HTTP: son N satir taranir (PostgREST `not.is.null` tip uyumsuzlugundan kacinmak icin).
  Future<TankReading?> _fetchLatestSingleForTank(String tankName) async {
    final Uri base = Uri.parse(endpoint);
    final Uri uri = base.replace(
      queryParameters: <String, String>{
        'select': 'name,value,created_at',
        'name': 'eq.$tankName',
        'order': 'created_at.desc',
        'limit': '40',
      },
    );

    final http.Response response = await _getWithTimeout(uri);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      if (kDebugMode) {
        debugPrint(
          'Supabase ($tankName) HTTP ${response.statusCode} ${response.body}',
        );
      }
      throw Exception('HTTP ${response.statusCode}');
    }

    final dynamic decoded = jsonDecode(response.body);
    if (decoded is! List<dynamic>) {
      throw Exception('Beklenmeyen yanit formati ($tankName)');
    }
    if (decoded.isEmpty) {
      return null;
    }
    final List<Map<String, dynamic>> matching = <Map<String, dynamic>>[];
    for (final dynamic row in decoded) {
      if (row is! Map) {
        continue;
      }
      final Map<String, dynamic> m = Map<String, dynamic>.from(row);
      if (_sensorRowMatchesTank(m, tankName)) {
        matching.add(m);
      }
    }
    if (matching.isEmpty) {
      if (kDebugMode && decoded.isNotEmpty) {
        debugPrint(
          'Supabase ($tankName): gelen ${decoded.length} satirda name="$tankName" '
          'eslesmedi; bu depo icin veri yok.',
        );
      }
      return null;
    }
    for (final Map<String, dynamic> m in matching) {
      final TankReading? r = _tankReadingFromRow(m, displayName: tankName);
      if (r != null && r.value != null) {
        return r;
      }
    }
    return _tankReadingFromRow(matching.first, displayName: tankName);
  }

  TankReading? _tankReadingFromRow(dynamic raw, {required String displayName}) {
    if (raw is! Map) {
      return null;
    }
    final Map<String, dynamic> row = Map<String, dynamic>.from(raw);
    final int? value = _parseSensorJsonValue(row['value']);
    final DateTime? createdAt = _parseCreatedAtUtc(row['created_at']);
    // created_at parse edilemezse karti tamamen dusurmeyelim
    final DateTime stamp = createdAt ?? DateTime.now().toUtc();
    return TankReading(
      name: displayName,
      value: value,
      createdAt: stamp,
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
      if (kDebugMode) {
        debugPrint(
          'Supabase chart HTTP ${response.statusCode} ${response.body}',
        );
      }
      throw Exception('HTTP ${response.statusCode}');
    }

    final dynamic decoded = jsonDecode(response.body);
    if (decoded is! List<dynamic>) {
      throw Exception('Beklenmeyen yanit formati');
    }

    final Map<String, TankDailyPoint> bestByDay = <String, TankDailyPoint>{};

    for (final dynamic row in decoded) {
      if (row is! Map) {
        continue;
      }
      final Map<String, dynamic> m = Map<String, dynamic>.from(row);
      if (!_sensorRowMatchesTank(m, tankName)) {
        continue;
      }
      final int? value = _parseSensorJsonValue(m['value']);
      final DateTime? createdAtUtc = _parseCreatedAtUtc(m['created_at']);
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
  // Dolu >=67 #007BFF; Normal 34–66 #00BFFF; Kritik 1–33 #FFC107; Boş 0 #DC3545; veri yok #6C757D
  final int v = level.clamp(0, 100);
  if (v >= 67) {
    return const Color(0xFF007BFF);
  }
  if (v >= 34) {
    return const Color(0xFF00BFFF);
  }
  if (v >= 1) {
    return const Color(0xFFFFC107);
  }
  return const Color(0xFFDC3545);
}

Color _colorForNullableLevel(int? level) {
  if (level == null) {
    return const Color(0xFF6C757D);
  }
  return _colorForLevel(level);
}
