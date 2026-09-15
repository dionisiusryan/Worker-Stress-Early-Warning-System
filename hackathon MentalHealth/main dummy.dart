import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'dart:convert';
import 'dart:async';
import 'dart:ui';

final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initNotifications();
  await initializeBackgroundService();
  runApp(const CommuteMindApp());
}

Future<void> initNotifications() async {
  if (kIsWeb) return;
  const AndroidInitializationSettings initializationSettingsAndroid =
      AndroidInitializationSettings('@mipmap/ic_launcher');
  const InitializationSettings initializationSettings = InitializationSettings(
    android: initializationSettingsAndroid,
  );
  await flutterLocalNotificationsPlugin.initialize(settings: initializationSettings);
}

Future<void> addAppLog(String action, String detail) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    List<String> logs = prefs.getStringList('app_debug_logs') ?? [];
    String timeStr = "${DateTime.now().hour.toString().padLeft(2, '0')}:${DateTime.now().minute.toString().padLeft(2, '0')}:${DateTime.now().second.toString().padLeft(2, '0')}";
    logs.insert(0, "[$timeStr] [$action] $detail");
    if (logs.length > 50) logs = logs.sublist(0, 50);
    await prefs.setStringList('app_debug_logs', logs);
  } catch (_) {}
}

Future<void> showRestNotification({String? title, String? body}) async {
  if (kIsWeb) return;
  const AndroidNotificationDetails androidPlatformChannelSpecifics = AndroidNotificationDetails(
    'rest_reminder_channel',
    'Pengingat Istirahat Komuter',
    channelDescription: 'Notifikasi otomatis dari server AI saat kelelahan tinggi',
    importance: Importance.max,
    priority: Priority.high,
  );
  const NotificationDetails platformChannelSpecifics = NotificationDetails(
    android: androidPlatformChannelSpecifics,
  );
  await flutterLocalNotificationsPlugin.show(
    id: 101,
    title: title ?? '☕ Istirahat Sejenak!',
    body: body ?? 'Data komuter berhasil diproses oleh Server AI Lokal.',
    notificationDetails: platformChannelSpecifics,
  );
}

Future<void> initializeBackgroundService() async {
  if (kIsWeb) return;
  final service = FlutterBackgroundService();
  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStartBackgroundService,
      autoStart: true,
      isForegroundMode: true,
      initialNotificationTitle: 'Commute Mind Companion',
      initialNotificationContent: 'Memantau perjalanan dan tingkat lelah secara pasif...',
      foregroundServiceNotificationId: 888,
    ),
    iosConfiguration: IosConfiguration(
      autoStart: true,
      onForeground: onStartBackgroundService,
    ),
  );
  await service.startService();
}

// --- FUNGSI CEK HARI LIBUR / TANGGAL MERAH NASIONAL (INDONESIA) ---
bool isNationalHoliday(DateTime date) {
  // Akhir pekan (Sabtu & Minggu) selalu libur
  if (date.weekday == DateTime.saturday || date.weekday == DateTime.sunday) {
    return true;
  }

  // Daftar Tanggal Merah / Hari Besar Nasional Tetap (Contoh Kalender 2026)
  List<String> fixedHolidays = [
    '01/01', // Tahun Baru Masehi
    '17/08', // Hari Kemerdekaan RI
    '25/12', // Hari Raya Natal
    '01/05', // Hari Buruh Internasional
    '01/06', // Hari Lahir Pancasila
  ];

  String dateFormatted = "${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}";
  return fixedHolidays.contains(dateFormatted);
}

// --- FUNGSI UTAMA SINKRONISASI, KOMUTER PRESISI & LOKASI DILUAR KANTOR ---
Future<void> runSyncProcess() async {
  final prefs = await SharedPreferences.getInstance();
  final isRegistered = prefs.getBool('is_registered') ?? false;
  if (!isRegistered) return;

  DateTime now = DateTime.now();
  String nowFormatted = "${now.day.toString().padLeft(2, '0')}/${now.month.toString().padLeft(2, '0')}/${now.year.toString().substring(2)}";

  bool isHolidayToday = isNationalHoliday(now);

  final officeLat = prefs.getDouble('office_lat') ?? 0.0;
  final officeLng = prefs.getDouble('office_lng') ?? 0.0;
  final homeLat = prefs.getDouble('home_lat') ?? 0.0;
  final homeLng = prefs.getDouble('home_lng') ?? 0.0;

  final targetOfficeWifi = prefs.getString('target_wifi') ?? '';
  final targetHomeWifi = prefs.getString('home_wifi') ?? '';
  final serverIp = prefs.getString('server_ip') ?? '192.168.1.15';
  final username = prefs.getString('username') ?? 'User';

  try {
    // --- LANGKAH 1: DETEKSI LOKASI ---
    // Prioritas: GPS dulu, Wi-Fi sebagai fallback jika GPS gagal/tidak tersedia.
    double distanceToHome = 5000.0;
    double distanceToOffice = 5000.0;
    bool hasAccurateLocation = false;
    String detectionSource = "Tidak Diketahui";

    bool isOfficeWifiMatched = false;
    bool isHomeWifiMatched = false;

    // --- CEK WI-FI SELALU PERTAMA (prioritas tertinggi) ---
    // Wi-Fi lebih reliable saat di dalam gedung dibanding GPS yang bisa drift.
    // Flag ini diset SEBELUM GPS, sehingga bisa meng-override hasil GPS yang tidak akurat.
    try {
      final info = NetworkInfo();
      String? currentWifi = await info.getWifiName();
      currentWifi = currentWifi?.replaceAll('"', '') ?? '';

      if (targetOfficeWifi.isNotEmpty && currentWifi == targetOfficeWifi) {
        isOfficeWifiMatched = true;
        // Wi-Fi kantor terdeteksi → paksa jarak ke kantor sangat dekat
        distanceToOffice = 50.0;
        distanceToHome = 15000.0;
        hasAccurateLocation = true;
        detectionSource = "Wi-Fi Kantor ($currentWifi)";
      } else if (targetHomeWifi.isNotEmpty && currentWifi == targetHomeWifi) {
        isHomeWifiMatched = true;
        // Wi-Fi rumah terdeteksi → paksa jarak ke rumah sangat dekat
        distanceToHome = 50.0;
        distanceToOffice = 15000.0;
        hasAccurateLocation = true;
        detectionSource = "Wi-Fi Rumah ($currentWifi)";
      }
    } catch (e) {
      await addAppLog("WARN", "Cek Wi-Fi gagal: $e");
    }

    // Coba GPS — hanya digunakan jika Wi-Fi tidak mendeteksi lokasi kantor/rumah
    // (GPS dapat override jika Wi-Fi tidak cocok, tapi Wi-Fi kantor/rumah selalu menang)
    if (!isOfficeWifiMatched && !isHomeWifiMatched) {
      try {
        LocationPermission permission = await Geolocator.checkPermission();
        if (permission == LocationPermission.denied) {
          permission = await Geolocator.requestPermission();
        }
        if (permission != LocationPermission.denied && permission != LocationPermission.deniedForever) {
          bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
          if (serviceEnabled) {
            Position pos = await Geolocator.getCurrentPosition(
              desiredAccuracy: LocationAccuracy.medium,
              timeLimit: const Duration(seconds: 6),
            );
            distanceToHome = Geolocator.distanceBetween(pos.latitude, pos.longitude, homeLat, homeLng);
            distanceToOffice = Geolocator.distanceBetween(pos.latitude, pos.longitude, officeLat, officeLng);
            hasAccurateLocation = true;
            detectionSource = "GPS";
          }
        }
      } catch (e) {
        await addAppLog("WARN", "GPS gagal: $e");
      }
    }

    await addAppLog("SYNC_CHECK",
        "Sumber: $detectionSource | Jarak Rumah: ${distanceToHome.toStringAsFixed(0)}m | Jarak Kantor: ${distanceToOffice.toStringAsFixed(0)}m | WifiRumah: $isHomeWifiMatched | WifiKantor: $isOfficeWifiMatched");

    // --- LANGKAH 2: RESET DATA JIKA HARI BARU ---
    String lastActiveDate = prefs.getString('last_active_date') ?? '';
    if (lastActiveDate != nowFormatted) {
      await prefs.setString('last_active_date', nowFormatted);
      await prefs.setInt('accumulated_work_minutes', 0);
      await prefs.setInt('accumulated_commute_minutes', 0);
      await prefs.setInt('home_minutes_today', 0);
      await prefs.remove('work_start_timestamp');
      await prefs.remove('commute_start_timestamp');
      await addAppLog("RESET", "Hari baru terdeteksi ($nowFormatted). Semua akumulator direset.");
    }

    int accumulatedWorkMinutes = prefs.getInt('accumulated_work_minutes') ?? 0;
    int accumulatedCommuteMinutes = prefs.getInt('accumulated_commute_minutes') ?? 0;
    int homeMinutesToday = prefs.getInt('home_minutes_today') ?? 0;

    // Baca timestamp aktif dari prefs (setelah kemungkinan reset di atas)
    String? workStartIso = prefs.getString('work_start_timestamp');
    String? commuteStartIso = prefs.getString('commute_start_timestamp');

    // --- LANGKAH 3: STATE MACHINE GEOFENCE ---
    if (isHolidayToday) {
      // ============================================================
      // STATUS: HARI LIBUR / TANGGAL MERAH
      // Tutup semua sesi yang mungkin masih terbuka, tidak tambah jam baru.
      // ============================================================
      if (workStartIso != null) {
        final delta = now.difference(DateTime.parse(workStartIso)).inMinutes;
        accumulatedWorkMinutes += delta;
        await prefs.setInt('accumulated_work_minutes', accumulatedWorkMinutes);
        await prefs.remove('work_start_timestamp');
        workStartIso = null;
      }
      if (commuteStartIso != null) {
        final delta = now.difference(DateTime.parse(commuteStartIso)).inMinutes;
        accumulatedCommuteMinutes += delta;
        await prefs.setInt('accumulated_commute_minutes', accumulatedCommuteMinutes);
        await prefs.remove('commute_start_timestamp');
        commuteStartIso = null;
      }
      await addAppLog("HOLIDAY", "Hari libur/tanggal merah. Semua jam dihentikan.");

    } else if (hasAccurateLocation) {
      // Wi-Fi match selalu menang atas perhitungan jarak GPS (override GPS drift di dalam gedung)
      final bool atOffice = isOfficeWifiMatched || (distanceToOffice < 200 && !isHomeWifiMatched);
      final bool atHome = isHomeWifiMatched || (distanceToHome < 200 && !isOfficeWifiMatched);
      // "Di Jalan" = tidak di rumah DAN tidak di kantor
      final bool onCommute = !atHome && !atOffice;

      if (atHome) {
        // ============================================================
        // STATUS: DI RUMAH
        // Tutup sesi kerja dan sesi komuter jika masih aktif.
        // ============================================================
        if (workStartIso != null) {
          final delta = now.difference(DateTime.parse(workStartIso)).inMinutes;
          accumulatedWorkMinutes += delta;
          await prefs.setInt('accumulated_work_minutes', accumulatedWorkMinutes);
          await prefs.remove('work_start_timestamp');
          workStartIso = null;
          await addAppLog("WORK_STOP", "Keluar dari zona kantor/perjalanan. Sesi kerja ditutup (+${delta}m). Total: ${accumulatedWorkMinutes}m");
        }
        if (commuteStartIso != null) {
          final delta = now.difference(DateTime.parse(commuteStartIso)).inMinutes;
          accumulatedCommuteMinutes += delta;
          await prefs.setInt('accumulated_commute_minutes', accumulatedCommuteMinutes);
          await prefs.remove('commute_start_timestamp');
          commuteStartIso = null;
          await addAppLog("COMMUTE_STOP", "Tiba di rumah. Sesi perjalanan ditutup (+${delta}m). Total: ${accumulatedCommuteMinutes}m");
        }
        homeMinutesToday += 5;
        await prefs.setInt('home_minutes_today', homeMinutesToday);
        await addAppLog("GEOFENCE", "Di rumah. Semua jam dihentikan.");

      } else if (atOffice) {
        // ============================================================
        // STATUS: DI KANTOR
        // Tutup sesi komuter jika aktif, mulai sesi kerja jika belum.
        // BUG FIX: Jangan sentuh accumulatedWorkMinutes di sini.
        //          Hanya buka work_start_timestamp jika belum ada.
        // ============================================================
        if (commuteStartIso != null) {
          final delta = now.difference(DateTime.parse(commuteStartIso)).inMinutes;
          accumulatedCommuteMinutes += delta;
          await prefs.setInt('accumulated_commute_minutes', accumulatedCommuteMinutes);
          await prefs.remove('commute_start_timestamp');
          commuteStartIso = null;
          await addAppLog("COMMUTE_STOP", "Tiba di kantor. Sesi perjalanan ditutup (+${delta}m). Total: ${accumulatedCommuteMinutes}m");
        }
        if (workStartIso == null) {
          // Mulai sesi kerja baru
          await prefs.setString('work_start_timestamp', now.toIso8601String());
          workStartIso = now.toIso8601String();
          await addAppLog("WORK_START", "Sesi kerja dimulai di kantor.");
        }
        await addAppLog("GEOFENCE", "Di kantor. Jam kerja berjalan. Accumulated: ${accumulatedWorkMinutes}m");

      } else if (onCommute) {
        // ============================================================
        // STATUS: DI JALAN (PERJALANAN PULANG / PERGI)
        // Tutup sesi kerja jika aktif (baru pulang dari kantor).
        // Mulai sesi komuter jika belum ada.
        // BUG FIX: Saat keluar kantor, work_start_timestamp ditutup dan
        //          accumulatedWorkMinutes diperbarui SEBELUM memulai commute.
        //          Ini yang sebelumnya menyebabkan jam kerja jadi 0.
        // ============================================================
        if (workStartIso != null) {
          final delta = now.difference(DateTime.parse(workStartIso)).inMinutes;
          // KRITIS: Simpan ke accumulated SEBELUM remove timestamp-nya
          accumulatedWorkMinutes += delta;
          await prefs.setInt('accumulated_work_minutes', accumulatedWorkMinutes);
          await prefs.remove('work_start_timestamp');
          workStartIso = null;
          await addAppLog("WORK_STOP", "Keluar kantor menuju jalan. Sesi kerja ditutup (+${delta}m). Total: ${accumulatedWorkMinutes}m");
        }
        if (commuteStartIso == null) {
          // Mulai sesi komuter baru (bisa perjalanan ke kantor ATAU pulang ke rumah)
          await prefs.setString('commute_start_timestamp', now.toIso8601String());
          commuteStartIso = now.toIso8601String();
          await addAppLog("COMMUTE_START", "Sesi perjalanan dimulai.");
        }
        await addAppLog("GEOFENCE", "Di jalan. Jam perjalanan berjalan. Accumulated: ${accumulatedCommuteMinutes}m");
      }
    }

    // --- LANGKAH 4: HITUNG TOTAL REAL-TIME (akumulasi + sesi yang sedang aktif) ---
    int totalWorkMinutes = accumulatedWorkMinutes;
    if (workStartIso != null) {
      totalWorkMinutes += now.difference(DateTime.parse(workStartIso)).inMinutes;
    }

    int totalCommuteMinutes = accumulatedCommuteMinutes;
    if (commuteStartIso != null) {
      totalCommuteMinutes += now.difference(DateTime.parse(commuteStartIso)).inMinutes;
    }

    await prefs.setInt('active_commute_minutes', totalCommuteMinutes);
    await prefs.setInt('active_work_minutes', totalWorkMinutes);
    await prefs.setInt('last_commute_duration', totalCommuteMinutes);
    await prefs.setDouble('last_work_hours', totalWorkMinutes / 60.0);

    // --- LANGKAH 5: TENTUKAN STATUS CUTI/LIBUR ---
    // Cuti terdeteksi jika di rumah seharian (>= 15 jam = 900 menit di rumah)
    bool isCutiOrLibur = isHolidayToday || (homeMinutesToday >= 900 && totalWorkMinutes == 0 && totalCommuteMinutes == 0);

    // --- LANGKAH 6: SIMPAN LOG RIWAYAT HARIAN ---
    List<String> rawHistory = prefs.getStringList('saved_monitoring_history') ?? [];

    int hoursW = totalWorkMinutes ~/ 60;
    int minsW = totalWorkMinutes % 60;
    int hoursC = totalCommuteMinutes ~/ 60;
    int minsC = totalCommuteMinutes % 60;

    String commuteStatusText = isHolidayToday
        ? 'Libur Nasional / Tanggal Merah'
        : (isCutiOrLibur ? 'Cuti/Libur (Dirumah)' : '${hoursC}j ${minsC}m');

    Map<String, String> todayLog = {
      'date': nowFormatted,
      'commute': commuteStatusText,
      'work': isHolidayToday ? '0j 0m' : '${hoursW}j ${minsW}m',
    };

    bool isAlreadyLoggedToday = false;
    int existingIndex = -1;
    for (int i = 0; i < rawHistory.length; i++) {
      try {
        Map<String, dynamic> decoded = jsonDecode(rawHistory[i]);
        if (decoded['date'] == nowFormatted) {
          isAlreadyLoggedToday = true;
          existingIndex = i;
          break;
        }
      } catch (_) {}
    }

    if (isAlreadyLoggedToday && existingIndex != -1) {
      rawHistory[existingIndex] = jsonEncode(todayLog);
    } else {
      rawHistory.insert(0, jsonEncode(todayLog));
      int currentDays = prefs.getInt('total_days') ?? 0;
      await prefs.setInt('total_days', currentDays + 1);
    }
    await prefs.setStringList('saved_monitoring_history', rawHistory);

    // --- LANGKAH 7: KIRIM KE SERVER (opsional, tidak blokir jika gagal) ---
    try {
      final response = await http.post(
        Uri.parse('http://$serverIp:8000/api/v1/commute-log'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'user_id': username,
          'durasi_komuter_menit': totalCommuteMinutes,
          'durasi_kerja_menit': totalWorkMinutes,
          'jarak_dari_rumah_km': distanceToHome / 1000.0,
          'status_perjalanan': isCutiOrLibur ? 'cuti' : 'normal',
        }),
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        await addAppLog("SYNC_SERVER", "Berhasil sinkronisasi ke server $serverIp.");
        final resData = jsonDecode(response.body);
        await prefs.setBool('trigger_dass21', resData['trigger_dass21'] ?? false);
        if (resData['ai_message'] != null) {
          await prefs.setString('cached_ai_message', resData['ai_message']);
        }
        await showRestNotification(
          title: resData['notification_title'],
          body: resData['notification_body'],
        );
      }
    } catch (e) {
      await addAppLog("WARN", "Server tidak dapat dijangkau (diabaikan): $e");
    }

  } catch (e) {
    await addAppLog("ERROR", "Gagal sinkronisasi: $e");
  }
}

@pragma('vm:entry-point')
void onStartBackgroundService(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();
  await addAppLog("SERVICE", "Background service aktif (berjalan berkala).");

  Timer.periodic(const Duration(minutes: 5), (timer) async {
    await runSyncProcess();
  });
}

Route createRoute(Widget page) {
  return PageRouteBuilder(
    pageBuilder: (context, animation, secondaryAnimation) => page,
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      const begin = Offset(1.0, 0.0);
      const end = Offset.zero;
      const curve = Curves.easeInOutCubic;
      var tween = Tween(begin: begin, end: end).chain(CurveTween(curve: curve));
      var offsetAnimation = animation.drive(tween);
      return SlideTransition(position: offsetAnimation, child: FadeTransition(opacity: animation, child: child));
    },
    transitionDuration: const Duration(milliseconds: 350),
  );
}

class CommuteMindApp extends StatelessWidget {
  const CommuteMindApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Commute Mind Companion',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF6366F1),
          primary: const Color(0xFF6366F1),
          secondary: const Color(0xFF8B5CF6),
        ),
        scaffoldBackgroundColor: const Color(0xFFF4F5FB),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF6366F1),
          foregroundColor: Colors.white,
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF6366F1),
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
      ),
      home: const SplashCheckScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class SplashCheckScreen extends StatefulWidget {
  const SplashCheckScreen({super.key});

  @override
  State<SplashCheckScreen> createState() => _SplashCheckScreenState();
}

class _SplashCheckScreenState extends State<SplashCheckScreen> {
  @override
  void initState() {
    super.initState();
    _checkRegistrationStatus();
  }

  Future<void> _checkRegistrationStatus() async {
    final prefs = await SharedPreferences.getInstance();
    final isRegistered = prefs.getBool('is_registered') ?? false;

    if (!mounted) return;
    if (isRegistered) {
      Navigator.pushReplacement(context, createRoute(const PinLockScreen()));
    } else {
      Navigator.pushReplacement(context, createRoute(const LoginSignupScreen()));
    }
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: CircularProgressIndicator(color: Color(0xFF6366F1))),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// SCREEN: Pilih Login atau Daftar
// ─────────────────────────────────────────────────────────────────────────────
class LoginSignupScreen extends StatelessWidget {
  const LoginSignupScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28.0, vertical: 40.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(Icons.directions_transit_filled, size: 72, color: Color(0xFF6366F1)),
              const SizedBox(height: 20),
              const Text(
                'Commute Mind',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: Color(0xFF6366F1)),
              ),
              const SizedBox(height: 8),
              const Text(
                'Pantau kesehatan mental perjalanan komuter kamu',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, color: Colors.grey),
              ),
              const SizedBox(height: 52),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF6366F1),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: () => Navigator.push(context, createRoute(const LoginScreen())),
                child: const Text('Masuk (Login)', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              ),
              const SizedBox(height: 14),
              OutlinedButton(
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Color(0xFF6366F1), width: 1.5),
                  foregroundColor: const Color(0xFF6366F1),
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: () => Navigator.push(context, createRoute(const RegisterScreen())),
                child: const Text('Daftar Akun Baru', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// SCREEN: Login — hanya username + PIN, cek lokal, langsung ke Dashboard
// ─────────────────────────────────────────────────────────────────────────────
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _usernameCtrl = TextEditingController();
  final _pinCtrl = TextEditingController();
  final _serverIpCtrl = TextEditingController();
  bool _isLoading = false;
  bool _isScanningServer = false;

  @override
  void initState() {
    super.initState();
    _loadSavedServerIp();
  }

  Future<void> _loadSavedServerIp() async {
    final prefs = await SharedPreferences.getInstance();
    _serverIpCtrl.text = prefs.getString('server_ip') ?? '192.168.1.15';
  }

  // Scan jaringan lokal untuk cari server (sama seperti di RegisterScreen)
  Future<bool> _pingServer(String ip) async {
    try {
      final res = await http.get(Uri.parse('http://$ip:8000/docs')).timeout(const Duration(milliseconds: 400));
      return res.statusCode == 200;
    } catch (_) { return false; }
  }

  Future<void> _autoDetectServer() async {
    setState(() => _isScanningServer = true);
    try {
      final current = _serverIpCtrl.text.trim();
      if (current.isNotEmpty && await _pingServer(current)) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(backgroundColor: Colors.teal, content: Text('Server ditemukan: $current')),
        );
        return;
      }
      // scan subnet
      try {
        final info = NetworkInfo();
        String? deviceIp = await info.getWifiIP();
        if (deviceIp != null) {
          final parts = deviceIp.split('.');
          if (parts.length == 4) {
            final subnet = '${parts[0]}.${parts[1]}.${parts[2]}';
            String? found;
            for (int b = 1; b <= 254 && found == null; b += 25) {
              final end = (b + 24).clamp(1, 254);
              final futures = [for (int i = b; i <= end; i++) _pingServer('$subnet.$i').then((ok) => ok ? '$subnet.$i' : null)];
              final results = await Future.wait(futures);
              found = results.firstWhere((r) => r != null, orElse: () => null);
            }
            if (found != null) {
              setState(() => _serverIpCtrl.text = found!);
              final prefs = await SharedPreferences.getInstance();
              await prefs.setString('server_ip', found);
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(backgroundColor: Colors.teal, content: Text('Server ditemukan: $found')),
              );
              return;
            }
          }
        }
      } catch (_) {}
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(backgroundColor: Colors.red, content: Text('Server tidak ditemukan di jaringan ini.')),
      );
    } finally {
      if (mounted) setState(() => _isScanningServer = false);
    }
  }

  Future<void> _doLogin() async {
    final username = _usernameCtrl.text.trim();
    final pin = _pinCtrl.text.trim();
    final serverIp = _serverIpCtrl.text.trim();

    if (username.isEmpty || pin.length != 4) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Masukkan username dan PIN 4 angka.')),
      );
      return;
    }

    setState(() => _isLoading = true);
    final prefs = await SharedPreferences.getInstance();

    // --- COBA LOGIN KE SERVER ---
    bool serverLoginSuccess = false;
    bool serverReachable = false;
    String serverMessage = '';

    try {
      final res = await http.post(
        Uri.parse('http://$serverIp:8000/api/v1/login'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'user_id': username, 'pin': pin}),
      ).timeout(const Duration(seconds: 6));

      if (res.statusCode == 200) {
        serverReachable = true;
        final body = jsonDecode(res.body);
        serverLoginSuccess = body['success'] == true;
        serverMessage = body['message'] ?? '';
      }
    } catch (_) {
      // Server tidak terjangkau — fallback ke lokal
      serverReachable = false;
    }

    setState(() => _isLoading = false);

    if (serverReachable) {
      if (!serverLoginSuccess) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(backgroundColor: Colors.deepOrange, content: Text(serverMessage.isNotEmpty ? serverMessage : 'Username atau PIN salah.')),
        );
        _pinCtrl.clear();
        return;
      }
      // Server login berhasil → simpan ke lokal & masuk
      await prefs.setString('username', username);
      await prefs.setString('user_pin', pin);
      await prefs.setString('server_ip', serverIp);
      await prefs.setBool('is_registered', true);
    } else {
      // --- FALLBACK: server tidak terjangkau, cek lokal ---
      final savedUsername = prefs.getString('username') ?? '';
      final savedPin = prefs.getString('user_pin') ?? '';
      final isRegistered = prefs.getBool('is_registered') ?? false;

      if (!isRegistered || savedUsername.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            backgroundColor: Colors.deepOrange,
            content: Text('Server tidak terjangkau dan belum ada data lokal. Sambungkan ke jaringan server terlebih dahulu.'),
          ),
        );
        return;
      }
      if (username != savedUsername || pin != savedPin) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            backgroundColor: Colors.orange,
            content: Text('Server offline. Login menggunakan data tersimpan di perangkat ini. Username atau PIN tidak cocok.'),
          ),
        );
        _pinCtrl.clear();
        return;
      }
      // Lokal cocok → izinkan masuk (mode offline)
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: Colors.teal,
          content: Text('Login offline berhasil (server tidak terjangkau).'),
          duration: Duration(seconds: 2),
        ),
      );
    }

    await addAppLog("LOGIN", "User '$username' login berhasil (server: $serverReachable).");
    if (!mounted) return;
    Navigator.pushReplacement(context, createRoute(const DashboardScreen()));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Masuk'),
        backgroundColor: const Color(0xFF6366F1),
        foregroundColor: Colors.white,
      ),
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 16),
              const Icon(Icons.lock_outline, size: 56, color: Color(0xFF6366F1)),
              const SizedBox(height: 20),

              // --- IP Server ---
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _serverIpCtrl,
                      decoration: const InputDecoration(
                        labelText: 'IP Server (misal: 192.168.1.15)',
                        prefixIcon: Icon(Icons.dns_outlined),
                        border: OutlineInputBorder(),
                      ),
                      keyboardType: TextInputType.number,
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    height: 56,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.teal.shade700,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                      ),
                      onPressed: _isScanningServer ? null : _autoDetectServer,
                      child: _isScanningServer
                          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : const Icon(Icons.radar, size: 20),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),

              // --- Username ---
              TextField(
                controller: _usernameCtrl,
                decoration: const InputDecoration(
                  labelText: 'Username',
                  prefixIcon: Icon(Icons.person_outline),
                  border: OutlineInputBorder(),
                ),
                textInputAction: TextInputAction.next,
              ),
              const SizedBox(height: 14),

              // --- PIN ---
              TextField(
                controller: _pinCtrl,
                keyboardType: TextInputType.number,
                maxLength: 4,
                obscureText: true,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 22, letterSpacing: 10),
                decoration: const InputDecoration(
                  labelText: 'PIN 4 Digit',
                  prefixIcon: Icon(Icons.pin_outlined),
                  border: OutlineInputBorder(),
                  counterText: '',
                ),
                onChanged: (val) { if (val.length == 4) _doLogin(); },
              ),
              const SizedBox(height: 24),

              SizedBox(
                height: 50,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF6366F1),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: _isLoading ? null : _doLogin,
                  child: _isLoading
                      ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                      : const Text('Masuk', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                ),
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: () => Navigator.pushReplacement(context, createRoute(const RegisterScreen())),
                child: const Text('Belum punya akun? Daftar di sini', style: TextStyle(color: Color(0xFF6366F1))),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class MapPickerDialog extends StatefulWidget {
  final LatLng initialCenter;
  final String title;

  const MapPickerDialog({
    super.key,
    required this.initialCenter,
    required this.title,
  });

  @override
  State<MapPickerDialog> createState() => _MapPickerDialogState();
}

class _MapPickerDialogState extends State<MapPickerDialog> {
  late LatLng _selectedLocation;
  late MapController _mapController;
  final TextEditingController _searchController = TextEditingController();
  bool _isSearching = false;

  @override
  void initState() {
    super.initState();
    _selectedLocation = widget.initialCenter;
    _mapController = MapController();
  }

  Future<void> _searchLocation() async {
    final query = _searchController.text.trim();
    if (query.isEmpty) return;
    setState(() => _isSearching = true);

    try {
      final url = Uri.parse('https://nominatim.openstreetmap.org/search?format=json&q=${Uri.encodeComponent(query)}');
      final res = await http.get(url, headers: {'User-Agent': 'CommuteMindApp/1.0'});

      if (res.statusCode == 200) {
        final List results = jsonDecode(res.body);
        if (results.isNotEmpty) {
          final lat = double.parse(results[0]['lat']);
          final lon = double.parse(results[0]['lon']);
          final newPos = LatLng(lat, lon);

          setState(() => _selectedLocation = newPos);
          _mapController.move(newPos, 16.0);

          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Lokasi ditemukan: ${results[0]['display_name']}')),
          );
        } else {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Lokasi tidak ditemukan.')),
          );
        }
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Gagal mencari lokasi: $e')));
    } finally {
      setState(() => _isSearching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog.fullscreen(
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.title),
          backgroundColor: const Color(0xFF6366F1),
          foregroundColor: Colors.white,
          actions: [
            TextButton.icon(
              style: TextButton.styleFrom(foregroundColor: Colors.white),
              onPressed: () => Navigator.pop(context, _selectedLocation),
              icon: const Icon(Icons.check),
              label: const Text('Gunakan Lokasi Ini', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        ),
        body: Stack(
          children: [
            FlutterMap(
              mapController: _mapController,
              options: MapOptions(
                initialCenter: widget.initialCenter,
                initialZoom: 15.0,
                onPositionChanged: (position, hasGesture) {
                  if (position.center != null) {
                    _selectedLocation = position.center!;
                  }
                },
              ),
              children: [
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'com.example.mental_health_app',
                ),
              ],
            ),
            const Center(
              child: Padding(
                padding: EdgeInsets.only(bottom: 35.0),
                child: Icon(Icons.location_on, size: 50, color: Colors.redAccent),
              ),
            ),
            Positioned(
              top: 15, left: 15, right: 15,
              child: Card(
                elevation: 6,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Row(
                    children: [
                      const Icon(Icons.search, color: Color(0xFF6366F1)),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: _searchController,
                          decoration: const InputDecoration(
                            hintText: 'Cari lokasi (misal: Stasiun Tenjo)...',
                            border: InputBorder.none,
                          ),
                          onSubmitted: (_) => _searchLocation(),
                        ),
                      ),
                      if (_isSearching)
                        const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF6366F1)))
                      else
                        IconButton(
                          icon: const Icon(Icons.arrow_forward, color: Color(0xFF6366F1)),
                          onPressed: _searchLocation,
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _usernameController = TextEditingController(text: 'Dionisius');
  final _pinController = TextEditingController();

  final _homeController = TextEditingController(text: 'Tenjo');
  double _homeLat = -6.3262;
  double _homeLng = 106.4631;

  final _officeController = TextEditingController(text: 'Genomics HUB');
  double _officeLat = -6.2088;
  double _officeLng = 106.8456;

  TimeOfDay _workStartTime = const TimeOfDay(hour: 8, minute: 0);
  TimeOfDay _workEndTime = const TimeOfDay(hour: 17, minute: 0);

  final _wifiController = TextEditingController(text: 'Office_Guest_WiFi');
  final _homeWifiController = TextEditingController(text: 'Home_WiFi_Name');
  final _serverIpController = TextEditingController(text: '192.168.1.15');
  bool _isLoadingCheck = false;
  bool _isManualSyncing = false;
  bool _isScanningServer = false;
  bool _isDetectingHomeWifi = false;
  bool _isDetectingOfficeWifi = false;
  String _originalUsername = '';
  bool _wasAlreadyRegistered = false;

  @override
  void initState() {
    super.initState();
    _loadExistingData();
  }

  Future<void> _loadExistingData() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _usernameController.text = prefs.getString('username') ?? 'Dionisius';
      _originalUsername = prefs.getString('username') ?? '';
      _wasAlreadyRegistered = prefs.getBool('is_registered') ?? false;
      _pinController.text = prefs.getString('user_pin') ?? '';

      _homeController.text = prefs.getString('home_location') ?? 'Tenjo';
      _homeLat = prefs.getDouble('home_lat') ?? -6.3262;
      _homeLng = prefs.getDouble('home_lng') ?? 106.4631;

      _officeController.text = prefs.getString('office_location') ?? 'Genomics HUB';
      _officeLat = prefs.getDouble('office_lat') ?? -6.2088;
      _officeLng = prefs.getDouble('office_lng') ?? 106.8456;

      String startStr = prefs.getString('work_start') ?? '08:00';
      List<String> startParts = startStr.split(':');
      _workStartTime = TimeOfDay(hour: int.parse(startParts[0]), minute: int.parse(startParts[1]));

      String endStr = prefs.getString('work_end') ?? '17:00';
      List<String> endParts = endStr.split(':');
      _workEndTime = TimeOfDay(hour: int.parse(endParts[0]), minute: int.parse(endParts[1]));

      _wifiController.text = prefs.getString('target_wifi') ?? 'Office_Guest_WiFi';
      _homeWifiController.text = prefs.getString('home_wifi') ?? 'Home_WiFi_Name';
      _serverIpController.text = prefs.getString('server_ip') ?? '192.168.1.15';
    });
  }

  Future<void> _pickTime(bool isStart) async {
    final TimeOfDay? picked = await showTimePicker(
      context: context,
      initialTime: isStart ? _workStartTime : _workEndTime,
      builder: (context, child) {
        return Theme(
          data: ThemeData.light().copyWith(
            colorScheme: const ColorScheme.light(
              primary: Color(0xFF6366F1),
              onPrimary: Colors.white,
              surface: Colors.white,
              onSurface: Colors.black87,
            ),
          ),
          child: child!,
        );
      },
    );
    if (picked != null) {
      setState(() {
        if (isStart) {
          _workStartTime = picked;
        } else {
          _workEndTime = picked;
        }
      });
    }
  }

  Future<void> _openMapPicker(bool isHome) async {
    final initialPoint = isHome ? LatLng(_homeLat, _homeLng) : LatLng(_officeLat, _officeLng);
    final LatLng? pickedLocation = await Navigator.push<LatLng>(
      context,
      MaterialPageRoute<LatLng>(
        builder: (_) => MapPickerDialog(
          initialCenter: initialPoint,
          title: isHome ? 'Pilih Lokasi Rumah' : 'Pilih Lokasi Kantor',
        ),
      ),
    );

    if (pickedLocation != null) {
      setState(() {
        if (isHome) {
          _homeLat = pickedLocation.latitude;
          _homeLng = pickedLocation.longitude;
        } else {
          _officeLat = pickedLocation.latitude;
          _officeLng = pickedLocation.longitude;
        }
      });
    }
  }

  // --- CEK IZIN & STATUS LOCATION SERVICE (WAJIB UNTUK MEMBACA NAMA WI-FI DI ANDROID) ---
  Future<bool> _ensureLocationReadyForWifi() async {
    // 1. Pastikan permission lokasi sudah diberikan
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
      if (!mounted) return false;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: Colors.deepOrange,
          content: Text('Izin Lokasi ditolak. Aktifkan izin Lokasi di Pengaturan Aplikasi agar SSID Wi-Fi bisa terbaca.'),
        ),
      );
      return false;
    }

    // 2. Pastikan toggle Location/GPS di sistem HP menyala (ini yang sering jadi penyebab error walau permission sudah OK)
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      if (!mounted) return false;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.deepOrange,
          content: const Text('Location/GPS di HP kamu sedang mati. Nyalakan dulu di Pengaturan > Lokasi.'),
          action: SnackBarAction(
            label: 'Buka Lokasi',
            textColor: Colors.white,
            onPressed: () => Geolocator.openLocationSettings(),
          ),
          duration: const Duration(seconds: 5),
        ),
      );
      return false;
    }

    return true;
  }

  // --- AUTODETECT WI-FI SAAT INI (RUMAH / KANTOR) ---
  Future<void> _detectCurrentWifi(bool isHome) async {
    setState(() {
      if (isHome) {
        _isDetectingHomeWifi = true;
      } else {
        _isDetectingOfficeWifi = true;
      }
    });

    try {
      bool ready = await _ensureLocationReadyForWifi();
      if (!ready) return;

      final info = NetworkInfo();
      String? wifiName = await info.getWifiName();
      wifiName = wifiName?.replaceAll('"', '');

      if (wifiName == null || wifiName.isEmpty || wifiName == '<unknown ssid>') {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            backgroundColor: Colors.deepOrange,
            content: Text('Belum terhubung ke Wi-Fi. Sambungkan HP ke Wi-Fi terlebih dahulu lalu coba lagi.'),
          ),
        );
        return;
      }

      setState(() {
        if (isHome) {
          _homeWifiController.text = wifiName!;
        } else {
          _wifiController.text = wifiName!;
        }
      });

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.teal,
          content: Text('Wi-Fi ${isHome ? 'Rumah' : 'Kantor'} terdeteksi: $wifiName'),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Gagal mendeteksi Wi-Fi: $e')));
    } finally {
      if (mounted) {
        setState(() {
          _isDetectingHomeWifi = false;
          _isDetectingOfficeWifi = false;
        });
      }
    }
  }

  // --- HELPER: CEK APAKAH IP MERUPAKAN SERVER YANG VALID ---
  Future<bool> _pingServerCandidate(String ip) async {
    try {
      final res = await http
          .get(Uri.parse('http://$ip:8000/docs'))
          .timeout(const Duration(milliseconds: 400));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  // --- AUTODETECT IP SERVER BACKEND DI JARINGAN LOKAL ---
  Future<void> _autoDetectServerIp() async {
    setState(() => _isScanningServer = true);

    try {
      bool ready = await _ensureLocationReadyForWifi();
      if (!ready) return;

      final info = NetworkInfo();
      String? deviceIp = await info.getWifiIP();

      if (deviceIp == null || deviceIp.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            backgroundColor: Colors.deepOrange,
            content: Text('Tidak dapat membaca alamat IP perangkat. Pastikan HP terhubung ke Wi-Fi.'),
          ),
        );
        return;
      }

      List<String> parts = deviceIp.split('.');
      if (parts.length != 4) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Format alamat IP perangkat tidak dikenali.')),
        );
        return;
      }
      String subnet = '${parts[0]}.${parts[1]}.${parts[2]}';

      String? foundIp;

      // 1. Coba dulu IP yang sedang diketik, siapa tahu sudah benar
      String currentTyped = _serverIpController.text.trim();
      if (currentTyped.isNotEmpty && await _pingServerCandidate(currentTyped)) {
        foundIp = currentTyped;
      }

      // 2. Scan seluruh subnet /24 secara paralel per-batch
      if (foundIp == null) {
        const batchSize = 25;
        for (int start = 1; start <= 254 && foundIp == null; start += batchSize) {
          int end = (start + batchSize - 1).clamp(1, 254);
          List<Future<String?>> futures = [];
          for (int i = start; i <= end; i++) {
            String candidate = '$subnet.$i';
            futures.add(_pingServerCandidate(candidate).then((ok) => ok ? candidate : null));
          }
          List<String?> results = await Future.wait(futures);
          foundIp = results.firstWhere((r) => r != null, orElse: () => null);
        }
      }

      if (!mounted) return;
      if (foundIp != null) {
        setState(() => _serverIpController.text = foundIp!);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(backgroundColor: Colors.teal, content: Text('Server AI ditemukan di: $foundIp')),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            backgroundColor: Colors.red,
            content: Text('Server tidak ditemukan di jaringan ini. Pastikan HP & server berada di Wi-Fi yang sama.'),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Gagal memindai jaringan: $e')));
    } finally {
      if (mounted) setState(() => _isScanningServer = false);
    }
  }

  Future<void> _saveRegistration() async {
    final username = _usernameController.text.trim();
    final pinInput = _pinController.text;

    if (username.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Nama user tidak boleh kosong!')));
      return;
    }
    if (pinInput.length != 4) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('PIN harus 4 angka!')));
      return;
    }

    final prefs = await SharedPreferences.getInstance();

    // Daftarkan ke server jika username berubah (registrasi baru atau ganti username)
    if (username != _originalUsername) {
      setState(() => _isLoadingCheck = true);
      final serverIp = _serverIpController.text.trim();

      try {
        final res = await http.post(
          Uri.parse('http://$serverIp:8000/api/v1/register'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'user_id': username, 'pin': pinInput}),
        ).timeout(const Duration(seconds: 6));

        if (res.statusCode == 200) {
          final body = jsonDecode(res.body);
          if (body['success'] != true) {
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                backgroundColor: Colors.deepOrange,
                content: Text(body['message'] ?? 'Username sudah digunakan, coba nama lain.'),
              ),
            );
            setState(() => _isLoadingCheck = false);
            return;
          }
        }
        // Jika server tidak terjangkau, lanjut simpan lokal saja
      } catch (_) {
        await addAppLog("WARN", "Server offline saat registrasi, disimpan lokal saja.");
      } finally {
        if (mounted) setState(() => _isLoadingCheck = false);
      }
    }

    final serverIp = _serverIpController.text.trim();

    await prefs.setString('username', username);
    await prefs.setString('user_pin', pinInput);

    await prefs.setString('home_location', _homeController.text);
    await prefs.setDouble('home_lat', _homeLat);
    await prefs.setDouble('home_lng', _homeLng);

    await prefs.setString('office_location', _officeController.text);
    await prefs.setDouble('office_lat', _officeLat);
    await prefs.setDouble('office_lng', _officeLng);

    String startFormatted = '${_workStartTime.hour.toString().padLeft(2, '0')}:${_workStartTime.minute.toString().padLeft(2, '0')}';
    String endFormatted = '${_workEndTime.hour.toString().padLeft(2, '0')}:${_workEndTime.minute.toString().padLeft(2, '0')}';

    await prefs.setString('work_start', startFormatted);
    await prefs.setString('work_end', endFormatted);

    await prefs.setString('target_wifi', _wifiController.text);
    await prefs.setString('home_wifi', _homeWifiController.text);
    await prefs.setString('server_ip', serverIp);

    // Reset semua data jika ini registrasi baru, ATAU jika username berubah
    // (user berbeda tidak boleh melihat data / chat user sebelumnya)
    bool usernameChanged = _wasAlreadyRegistered && username != _originalUsername;
    if (!_wasAlreadyRegistered || usernameChanged) {
      await prefs.setInt('total_days', 0);
      await prefs.setInt('accumulated_work_minutes', 0);
      await prefs.setInt('accumulated_commute_minutes', 0);
      await prefs.setInt('active_commute_minutes', 0);
      await prefs.setInt('active_work_minutes', 0);
      await prefs.setInt('home_minutes_today', 0);
      await prefs.remove('work_start_timestamp');
      await prefs.remove('commute_start_timestamp');
      await prefs.setBool('trigger_dass21', false);
      await prefs.remove('saved_monitoring_history');
      await prefs.remove('cached_ai_message');
      // Hapus motivasi harian agar tidak muncul kata motivasi milik user lama
      await prefs.remove('daily_motivation_text');
      await prefs.remove('daily_motivation_date');
      await prefs.remove('last_active_date');
      // PENTING: Hapus riwayat chat saat user baru / ganti user
      // agar chat user lama tidak terlihat oleh user baru
      await prefs.remove('saved_chat_history');
      await addAppLog("RESET", "Data & chat lama dihapus untuk user baru: $username");
    }

    await prefs.setBool('is_registered', true);
    await addAppLog("CONFIG", "Registrasi berhasil disimpan untuk user: $username");

    runSyncProcess();

    if (!mounted) return;
    // Setelah daftar, langsung ke Dashboard (tidak perlu PIN lagi karena baru saja diisi)
    Navigator.pushReplacement(context, createRoute(const DashboardScreen()));
  }

  Future<void> _triggerManualSync() async {
    setState(() => _isManualSyncing = true);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('server_ip', _serverIpController.text.trim());
    await prefs.setString('target_wifi', _wifiController.text.trim());
    await prefs.setString('home_wifi', _homeWifiController.text.trim());

    await runSyncProcess();

    setState(() => _isManualSyncing = false);
    if (!mounted) return;
    
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        backgroundColor: Color(0xFF6366F1),
        content: Text('Sinkronisasi waktu riil berhasil diperbarui!'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    String startStr = '${_workStartTime.hour.toString().padLeft(2, '0')}:${_workStartTime.minute.toString().padLeft(2, '0')}';
    String endStr = '${_workEndTime.hour.toString().padLeft(2, '0')}:${_workEndTime.minute.toString().padLeft(2, '0')}';

    return Scaffold(
      appBar: AppBar(title: const Text('Registrasi / Pengaturan Hybrid GPS & Wi-Fi'), backgroundColor: const Color(0xFF6366F1), foregroundColor: Colors.white),
      resizeToAvoidBottomInset: true,
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(controller: _usernameController, decoration: const InputDecoration(labelText: 'Nama User (Unik)', border: OutlineInputBorder())),
            const SizedBox(height: 10),
            TextField(controller: _pinController, keyboardType: TextInputType.number, maxLength: 4, obscureText: true, decoration: const InputDecoration(labelText: 'PIN (4 Digit)', border: OutlineInputBorder())),
            const SizedBox(height: 15),

            Row(
              children: [
                Expanded(child: TextField(controller: _homeController, decoration: const InputDecoration(labelText: 'Lokasi Rumah (GPS)', border: OutlineInputBorder()))),
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF6366F1), foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 12)),
                  onPressed: () => _openMapPicker(true),
                  icon: const Icon(Icons.map),
                  label: const Text('Peta'),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _homeWifiController,
                    decoration: const InputDecoration(labelText: 'SSID Wi-Fi Rumah (Backup GPS / Deteksi Cuti)', border: OutlineInputBorder()),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.teal.shade700, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 12)),
                  onPressed: _isDetectingHomeWifi ? null : () => _detectCurrentWifi(true),
                  child: _isDetectingHomeWifi
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.wifi_find),
                ),
              ],
            ),
            const SizedBox(height: 15),

            Row(
              children: [
                Expanded(child: TextField(controller: _officeController, decoration: const InputDecoration(labelText: 'Lokasi Kantor (GPS)', border: OutlineInputBorder()))),
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF6366F1), foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 12)),
                  onPressed: () => _openMapPicker(false),
                  icon: const Icon(Icons.map),
                  label: const Text('Peta'),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _wifiController,
                    decoration: const InputDecoration(labelText: 'SSID Wi-Fi Kantor (Backup GPS / Jam Kerja)', border: OutlineInputBorder()),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.teal.shade700, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 12)),
                  onPressed: _isDetectingOfficeWifi ? null : () => _detectCurrentWifi(false),
                  child: _isDetectingOfficeWifi
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.wifi_find),
                ),
              ],
            ),
            const SizedBox(height: 15),

            Row(
              children: [
                Expanded(
                  child: InkWell(
                    onTap: () => _pickTime(true),
                    child: InputDecorator(
                      decoration: const InputDecoration(labelText: 'Jam Masuk Kerja', border: OutlineInputBorder()),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(startStr, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                          const Icon(Icons.access_time, color: Color(0xFF6366F1), size: 20),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: InkWell(
                    onTap: () => _pickTime(false),
                    child: InputDecorator(
                      decoration: const InputDecoration(labelText: 'Jam Pulang Kerja', border: OutlineInputBorder()),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(endStr, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                          const Icon(Icons.access_time_filled, color: Color(0xFF6366F1), size: 20),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 15),

            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _serverIpController,
                    decoration: const InputDecoration(labelText: 'IP Server Backend (Contoh: 192.168.1.15)', border: OutlineInputBorder()),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.teal.shade700, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 12)),
                  onPressed: _isScanningServer ? null : _autoDetectServerIp,
                  icon: _isScanningServer
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.radar, size: 18),
                  label: Text(_isScanningServer ? 'Mencari...' : 'Cari Otomatis', style: const TextStyle(fontSize: 12)),
                ),
              ],
            ),
            const SizedBox(height: 20),
            
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF6366F1), foregroundColor: Colors.white),
                onPressed: _isLoadingCheck ? null : _saveRegistration,
                child: _isLoadingCheck
                    ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                    : const Text('Simpan & Ke Login PIN'),
              ),
            ),
            const SizedBox(height: 12),

            Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 50,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.teal.shade700,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      onPressed: _isManualSyncing ? null : _triggerManualSync,
                      icon: _isManualSyncing 
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                        : const Icon(Icons.sync_rounded),
                      label: Text(_isManualSyncing ? 'Sinkronisasi...' : 'Sinkronisasi Manual', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: SizedBox(
                    height: 50,
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: Color(0xFF6366F1), width: 1.5),
                        foregroundColor: const Color(0xFF6366F1),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      onPressed: () => Navigator.push(context, createRoute(const AppLogsScreen())),
                      icon: const Icon(Icons.receipt_long_rounded, size: 18),
                      label: const Text('Lihat Log', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }
}

class AppLogsScreen extends StatefulWidget {
  const AppLogsScreen({super.key});

  @override
  State<AppLogsScreen> createState() => _AppLogsScreenState();
}

class _AppLogsScreenState extends State<AppLogsScreen> {
  List<String> _logs = [];

  @override
  void initState() {
    super.initState();
    _loadLogs();
  }

  Future<void> _loadLogs() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _logs = prefs.getStringList('app_debug_logs') ?? ['Belum ada log terekam.'];
    });
  }

  Future<void> _clearLogs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('app_debug_logs');
    setState(() => _logs = ['Log dibersihkan.']);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Log Aktivitas Riil'),
        backgroundColor: const Color(0xFF6366F1),
        foregroundColor: Colors.white,
        actions: [
          IconButton(icon: const Icon(Icons.delete_sweep), onPressed: _clearLogs),
          IconButton(icon: const Icon(Icons.refresh), onPressed: _loadLogs),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: const Color(0xFFEEF2FF), borderRadius: BorderRadius.circular(10)),
              child: const Text(
                'Waktu kerja, komuter, hari libur (tanggal merah), serta perjalanan dari/ke luar kantor dilacak secara presisi otomatis.',
                style: TextStyle(fontSize: 12, height: 1.4, color: Color(0xFF312E81)),
              ),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: Container(
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: Colors.grey.shade300)),
                child: ListView.separated(
                  padding: const EdgeInsets.all(12),
                  itemCount: _logs.length,
                  separatorBuilder: (_, __) => const Divider(height: 12),
                  itemBuilder: (context, index) => Text(_logs[index], style: const TextStyle(fontFamily: 'monospace', fontSize: 12, height: 1.3)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class PinLockScreen extends StatefulWidget {
  const PinLockScreen({super.key});

  @override
  State<PinLockScreen> createState() => _PinLockScreenState();
}

class _PinLockScreenState extends State<PinLockScreen> {
  final _pinInputController = TextEditingController();

  Future<void> _verifyPin() async {
    final prefs = await SharedPreferences.getInstance();
    final savedPin = prefs.getString('user_pin');

    if (_pinInputController.text == savedPin) {
      if (!mounted) return;
      Navigator.pushReplacement(context, createRoute(const DashboardScreen()));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('PIN Salah! Silakan coba lagi.')));
      _pinInputController.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.lock, size: 80, color: Color(0xFF6366F1)),
              const SizedBox(height: 16),
              const Text('Masukkan PIN 4-Digit', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
              const SizedBox(height: 20),
              TextField(
                controller: _pinInputController,
                keyboardType: TextInputType.number,
                maxLength: 4,
                obscureText: true,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 24, letterSpacing: 8),
                decoration: const InputDecoration(border: OutlineInputBorder()),
                onChanged: (val) {
                  if (val.length == 4) _verifyPin();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  String _username = '';
  String _serverIp = '192.168.1.15';

  bool _isServerOnline = false;
  bool _isLoading = false;
  bool _triggerDass21 = false;

  int _totalDaysMonitoring = 0;
  int _commuteDurationMinutes = 0;
  double _totalWorkHours = 0.0;

  String? _aiMessage;
  String _dailyMotivation = '';
  Timer? _healthTimer;
  Timer? _uiRefreshTimer;

  // --- Kumpulan kata motivasi harian berdasarkan kondisi ---
  // Dipilih secara acak tiap kali user membuka dashboard (bukan per-hari).
  // Setiap bucket berkaitan langsung dengan situasi komuter / beban kerja user.

  static const List<String> _motivasiNormal = [
    'Perjalanan panjangmu hari ini adalah bukti semangatmu. Pulang dengan selamat, istirahat yang layak. 🌟',
    'Kamu sudah bertahan melewati padatnya jalur komuter. Itu bukan hal kecil — itu kekuatan! 💪',
    'Satu hari lagi terlewati dengan baik. Jangan lupa apresiasi diri sebelum tidur malam ini. 🌙',
    'Perjalanan jauh bukan penghalang, tapi cermin ketangguhan. Kamu luar biasa hari ini! 🚂',
    'Dari rumah ke kantor, dari kantor ke rumah — setiap menit perjalananmu itu perjuangan nyata. 🏅',
    'Istirahat adalah bagian dari produktivitas. Nikmati waktu santaimu malam ini tanpa rasa bersalah. ☕',
    'Kamu boleh lelah, tapi jangan lupa bahwa kamu sudah melakukan yang terbaik hari ini. 🌿',
  ];

  static const List<String> _motivasiBebanTinggi = [
    'Hari ini terasa berat, tapi kamu tetap bertahan. Itu bukan hal biasa — itu kehebatan. 🔥',
    'Tubuhmu sudah bekerja keras hari ini. Saatnya beri dia istirahat yang pantas dia terima. 😴',
    'Jam kerja panjang bukan tanda keberhasilan sejati — keseimbangan adalah kuncinya. Jaga dirimu! ⚖️',
    'Kamu boleh berhenti sejenak. Istirahat bukan kelemahan, itu investasi untuk esok hari. 🌱',
    'Jangan tunda waktu istirahat. Tubuh dan pikiranmu butuh recharge setelah hari yang panjang ini. 🔋',
    'Pekerja keras yang cerdas tahu kapan harus berhenti. Kamu sudah cukup hari ini. ✋',
  ];

  static const List<String> _motivasiKomutorPanjang = [
    'Perjalananmu lebih dari 1 jam — itu waktu yang tidak sedikit. Gunakan untuk istirahat pikiranmu. 🎧',
    'Komuter panjang setiap hari bukan beban kecil. Tapi kamu melewatinya — sungguh luar biasa! 🚇',
    'Jarak jauh antara rumah dan kantor tidak mengurangi nilaimu. Justru membuktikan dedikasimu. 🌟',
    'Coba manfaatkan perjalanan pulang untuk bernapas dalam dan lepaskan beban hari ini. 🍃',
    'Setiap stasiun yang kamu lewati adalah satu langkah lebih dekat ke rumah. Hampir sampai! 🏠',
  ];

  static const List<String> _motivasiLibur = [
    'Hari ini adalah hari istirahatmu. Lepaskan pikiran kerja dan nikmati momen bersama orang tersayang. 🌈',
    'Akhir pekan adalah hakmu. Jangan ragu untuk tidak melakukan apa-apa — itu pun produktif! 😊',
    'Hari libur bukan untuk diisi pekerjaan. Isi dengan hal-hal yang membuat hatimu senang. 🎉',
    'Istirahat yang baik adalah kunci produktivitas minggu depan. Nikmati harimu hari ini! ☀️',
    'Tubuhmu sudah bekerja keras sepekan penuh. Hari ini giliran pikiranmu untuk bebas. 🕊️',
  ];

  static const List<String> _motivasiAwal = [
    'Selamat datang! Kamu sudah melangkah — itu awal yang luar biasa. 🚀',
    'Perjalanan seribu mil dimulai dari satu langkah. Kamu sudah memulainya hari ini! 👣',
    'Baru mulai memantau? Bagus! Konsistensi kecil setiap hari membawa perubahan besar. 📈',
    'Hari pertama selalu yang terberat. Tapi kamu sudah melewatinya — selamat! 🎊',
  ];

  /// Pilih motivasi harian yang relevan dengan kondisi user saat ini.
  /// Dipilih acak dari bucket yang sesuai → berubah tiap kali app dibuka.
  String _pickDailyMotivation({
    required int commuteMins,
    required double workHours,
    required int totalDays,
    required bool isHolidayOrWeekend,
  }) {
    final random = DateTime.now().millisecondsSinceEpoch;

    if (totalDays == 0) {
      return _motivasiAwal[random % _motivasiAwal.length];
    }

    if (isHolidayOrWeekend) {
      return _motivasiLibur[random % _motivasiLibur.length];
    }

    final bool longCommute = commuteMins > 60;
    final bool heavyWork = workHours >= 9.0;

    if (heavyWork) {
      return _motivasiBebanTinggi[random % _motivasiBebanTinggi.length];
    }
    if (longCommute) {
      return _motivasiKomutorPanjang[random % _motivasiKomutorPanjang.length];
    }
    return _motivasiNormal[random % _motivasiNormal.length];
  }

  @override
  void initState() {
    super.initState();
    _loadUserData();
    _startHealthCheckTimer();
    
    _uiRefreshTimer = Timer.periodic(const Duration(seconds: 30), (_) => _loadUserData());
  }

  @override
  void dispose() {
    _healthTimer?.cancel();
    _uiRefreshTimer?.cancel();
    super.dispose();
  }

  /// Format durasi jam kerja agar konsisten dengan baris lain:
  /// - 0 menit  -> "0 Menit"
  /// - < 60 mnt -> "XX Menit"
  /// - >= 60 mnt -> "X Jam Y Menit"
  String _formatWorkDuration(int totalMinutes) {
    if (totalMinutes <= 0) return '0 Menit';
    final int h = totalMinutes ~/ 60;
    final int m = totalMinutes % 60;
    if (h == 0) return '$m Menit';
    if (m == 0) return '$h Jam';
    return '$h Jam $m Menit';
  }

  Future<void> _showManualTimeInput({required bool isCommute}) async {
    final currentMinutes = isCommute ? _commuteDurationMinutes : (_totalWorkHours * 60).round();
    final initHours = currentMinutes ~/ 60;
    final initMins = currentMinutes % 60;

    final hoursCtrl = TextEditingController(text: initHours.toString());
    final minsCtrl = TextEditingController(text: initMins.toString());

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            Icon(
              isCommute ? Icons.directions_transit : Icons.work_outline,
              color: isCommute ? Colors.orange : const Color(0xFF6366F1),
              size: 22,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                isCommute ? 'Input Manual Waktu Perjalanan' : 'Input Manual Jam Kerja',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFFFFF8E1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFFFFCC02)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.info_outline, size: 16, color: Color(0xFFF59E0B)),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Gunakan ini jika ada selisih akibat GPS/WiFi tidak terdeteksi atau background service terlambat.',
                      style: TextStyle(fontSize: 11.5, color: Color(0xFF92400E), height: 1.4),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: hoursCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Jam',
                      suffixText: 'jam',
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: minsCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Menit',
                      suffixText: 'mnt',
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Batal'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: isCommute ? Colors.orange : const Color(0xFF6366F1),
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Simpan'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    final int newHours = int.tryParse(hoursCtrl.text.trim()) ?? 0;
    final int newMins = int.tryParse(minsCtrl.text.trim()) ?? 0;
    final int totalNewMinutes = (newHours * 60 + newMins).clamp(0, 1440);

    final prefs = await SharedPreferences.getInstance();
    if (isCommute) {
      // Tutup sesi aktif jika ada, lalu set akumulasi ke nilai manual
      await prefs.setInt('accumulated_commute_minutes', totalNewMinutes);
      await prefs.remove('commute_start_timestamp');
      await prefs.setInt('active_commute_minutes', totalNewMinutes);
      await prefs.setInt('last_commute_duration', totalNewMinutes);
      await addAppLog("MANUAL_INPUT", "Waktu perjalanan diset manual: ${totalNewMinutes}m");
    } else {
      // Tutup sesi aktif jika ada, lalu set akumulasi ke nilai manual
      await prefs.setInt('accumulated_work_minutes', totalNewMinutes);
      await prefs.remove('work_start_timestamp');
      await prefs.setInt('active_work_minutes', totalNewMinutes);
      await prefs.setDouble('last_work_hours', totalNewMinutes / 60.0);
      await addAppLog("MANUAL_INPUT", "Jam kerja diset manual: ${totalNewMinutes}m");
    }

    _loadUserData();

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: isCommute ? Colors.orange.shade700 : const Color(0xFF6366F1),
        content: Text(
          isCommute
              ? 'Waktu perjalanan diperbarui: ${newHours}j ${newMins}m'
              : 'Jam kerja diperbarui: ${newHours}j ${newMins}m',
        ),
      ),
    );
  }

  Future<void> _loadUserData() async {
    final prefs = await SharedPreferences.getInstance();
    
    int workMins = prefs.getInt('accumulated_work_minutes') ?? 0;
    String? workStart = prefs.getString('work_start_timestamp');
    if (workStart != null) {
      workMins += DateTime.now().difference(DateTime.parse(workStart)).inMinutes;
    }

    int commuteMins = prefs.getInt('accumulated_commute_minutes') ?? 0;
    String? commuteStart = prefs.getString('commute_start_timestamp');
    if (commuteStart != null) {
      commuteMins += DateTime.now().difference(DateTime.parse(commuteStart)).inMinutes;
    }

    final int totalDays = prefs.getInt('total_days') ?? 0;
    final bool triggerDass = prefs.getBool('trigger_dass21') ?? false;
    final DateTime now = DateTime.now();
    final bool isWeekendOrHoliday = isNationalHoliday(now);

    // Bangkitkan motivasi harian baru setiap kali _loadUserData dipanggil
    // (termasuk tiap 30 detik refresh, tapi juga saat pertama buka app)
    final String motivation = _pickDailyMotivation(
      commuteMins: commuteMins,
      workHours: workMins / 60.0,
      totalDays: totalDays,
      isHolidayOrWeekend: isWeekendOrHoliday,
    );

    if (!mounted) return;
    setState(() {
      _username = prefs.getString('username') ?? 'User';
      _serverIp = prefs.getString('server_ip') ?? '192.168.1.15';
      _totalDaysMonitoring = totalDays;
      _commuteDurationMinutes = commuteMins;
      _totalWorkHours = workMins / 60.0;
      _triggerDass21 = triggerDass;
      _aiMessage = prefs.getString('cached_ai_message');
      _dailyMotivation = motivation;
    });

    _checkServerHealth();
  }

  Future<void> _checkServerHealth() async {
    try {
      final res = await http.get(Uri.parse('http://$_serverIp:8000/docs')).timeout(const Duration(seconds: 3));
      bool wasOnline = _isServerOnline;
      bool isNowOnline = (res.statusCode == 200);

      setState(() => _isServerOnline = isNowOnline);

      if (!wasOnline && isNowOnline) {
        _sendDataToFastApi();
      }
    } catch (_) {
      setState(() => _isServerOnline = false);
    }
  }

  void _startHealthCheckTimer() {
    _healthTimer = Timer.periodic(const Duration(seconds: 5), (_) => _checkServerHealth());
  }

  Future<void> _sendDataToFastApi() async {
    if (_isLoading) return;
    setState(() => _isLoading = true);

    try {
      int workMinutes = (_totalWorkHours * 60).round();

      final res = await http.post(
        Uri.parse('http://$_serverIp:8000/api/v1/commute-log'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'user_id': _username,
          'durasi_komuter_menit': _commuteDurationMinutes,
          'durasi_kerja_menit': workMinutes,
        }),
      ).timeout(const Duration(seconds: 60));

      if (res.statusCode == 200) {
        final body = jsonDecode(res.body);
        final prefs = await SharedPreferences.getInstance();

        bool trigger = body['trigger_dass21'] ?? false;
        String newAiMsg = body['ai_message'] ?? '';

        await prefs.setBool('trigger_dass21', trigger);
        if (newAiMsg.isNotEmpty) {
          await prefs.setString('cached_ai_message', newAiMsg);
        }

        setState(() {
          _aiMessage = newAiMsg;
          _triggerDass21 = trigger;
        });
      }
    } catch (_) {
    } finally {
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Halo, $_username'),
        backgroundColor: const Color(0xFF6366F1),
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () {
              Navigator.push(context, createRoute(const RegisterScreen())).then((_) => _loadUserData());
            },
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: _isServerOnline ? Colors.green.shade100 : Colors.red.shade100,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(_isServerOnline ? Icons.check_circle : Icons.error, color: _isServerOnline ? Colors.green : Colors.red, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _isServerOnline ? 'Server Terhubung ($_serverIp:8000)' : 'Server Offline ($_serverIp:8000)',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: _isServerOnline ? Colors.green.shade900 : Colors.red.shade900),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            SizedBox(
              width: double.infinity,
              height: 52,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: _triggerDass21 ? Colors.deepOrange.shade700 : const Color(0xFF6366F1),
                  foregroundColor: Colors.white,
                  elevation: 3,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: () {
                  Navigator.push(context, createRoute(const Dass21Screen())).then((_) => _loadUserData());
                },
                icon: Icon(_triggerDass21 ? Icons.warning_amber_rounded : Icons.psychology_alt, size: 26),
                label: Text(
                  _triggerDass21 ? '⚠️ Periksa DASS-21 & IBM BOB!' : 'Yuk Cek Kesehatan Mentalmu !',
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                ),
              ),
            ),
            const SizedBox(height: 10),

            SizedBox(
              width: double.infinity,
              height: 50,
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Color(0xFF6366F1), width: 1.5),
                  foregroundColor: const Color(0xFF6366F1),
                  backgroundColor: const Color(0xFFEEF2FF),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: () {
                  Navigator.push(context, createRoute(const CurhatChatScreen()));
                },
                icon: const Icon(Icons.chat_bubble_outline, size: 22),
                label: const Text('💬 Coba Chat dengan AI yuk!', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
              ),
            ),
            const SizedBox(height: 16),

            Card(
              elevation: 2,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: () {
                        Navigator.push(
                          context,
                          createRoute(const MonitoringHistoryScreen()),
                        ).then((_) => _loadUserData());
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4.0),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Row(
                              children: const [
                                Text('Total Hari Monitoring:', style: TextStyle(color: Colors.grey, fontWeight: FontWeight.w600)),
                                SizedBox(width: 4),
                                Icon(Icons.touch_app, size: 16, color: Color(0xFF6366F1)),
                              ],
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(color: const Color(0xFFEEF2FF), borderRadius: BorderRadius.circular(20)),
                              child: Text('$_totalDaysMonitoring Hari', style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF6366F1))),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const Divider(height: 20),

                    InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: () => _showManualTimeInput(isCommute: true),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6.0),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: const [
                                Text('Durasi Perjalanan Komuter:', style: TextStyle(fontSize: 13)),
                                SizedBox(width: 4),
                                Icon(Icons.edit, size: 13, color: Colors.orange),
                              ],
                            ),
                            Text(
                              '$_commuteDurationMinutes Menit',
                              style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.orange, fontSize: 13),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),

                    InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: () => _showManualTimeInput(isCommute: false),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6.0),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: const [
                                Text('Total Jam Kerja:', style: TextStyle(fontSize: 13)),
                                SizedBox(width: 4),
                                Icon(Icons.edit, size: 13, color: Color(0xFF6366F1)),
                              ],
                            ),
                            Text(
                              _formatWorkDuration((_totalWorkHours * 60).round()),
                              style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF6366F1), fontSize: 13),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // --- SECTION: SAPAAN + MOTIVASI HARIAN ---
            // Tampil offline, berubah tiap buka app, relevan dengan kondisi komuter/kerja user.
            Card(
              elevation: 2,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              color: const Color(0xFFF0FDF4),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('🌱', style: TextStyle(fontSize: 24)),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Halo, $_username! 👋',
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 15,
                              color: Color(0xFF166534),
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            _dailyMotivation.isNotEmpty
                                ? _dailyMotivation
                                : 'Semangat hari ini! Kamu sudah melangkah — itu yang terpenting. 🌟',
                            style: const TextStyle(
                              fontSize: 13.5,
                              height: 1.5,
                              color: Color(0xFF14532D),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // --- SECTION: ANALISIS PEMULIHAN DARI SERVER AI ---
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Saran Pemulihan Mental AI:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                if (_isLoading)
                  const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF6366F1))),
              ],
            ),
            const SizedBox(height: 8),

            if (_isLoading && (_aiMessage == null || _aiMessage!.isEmpty))
              // Loading state: AI sedang diproses server
              Card(
                color: const Color(0xFFEEF2FF),
                elevation: 2,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 20),
                  child: Row(
                    children: [
                      SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF6366F1))),
                      SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'AI sedang menganalisis data perjalananmu...',
                          style: TextStyle(fontSize: 13, color: Color(0xFF6366F1), fontStyle: FontStyle.italic),
                        ),
                      ),
                    ],
                  ),
                ),
              )
            else if (_aiMessage != null && _aiMessage!.isNotEmpty)
              Card(
                color: const Color(0xFFEEF2FF),
                elevation: 2,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.auto_awesome, color: Color(0xFF6366F1)),
                          const SizedBox(width: 8),
                          const Expanded(
                            child: Text('Analisis AI', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Color(0xFF6366F1))),
                          ),
                          if (!_isServerOnline)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(color: Colors.grey.shade300, borderRadius: BorderRadius.circular(10)),
                              child: const Text('Cache', style: TextStyle(fontSize: 10, color: Colors.black87)),
                            ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(_aiMessage!, style: const TextStyle(height: 1.4, fontSize: 14)),
                    ],
                  ),
                ),
              )
            else if (!_isServerOnline)
              // Server offline dan tidak ada cache — tampilkan info minimal
              Card(
                elevation: 1,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Row(
                    children: [
                      Icon(Icons.cloud_off_outlined, color: Colors.grey.shade500, size: 22),
                      const SizedBox(width: 10),
                      const Expanded(
                        child: Text(
                          'Server AI belum terjangkau. Saran pemulihan akan muncul otomatis saat server terhubung.',
                          style: TextStyle(fontSize: 13, color: Colors.black54, height: 1.4),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class MonitoringHistoryScreen extends StatefulWidget {
  const MonitoringHistoryScreen({super.key});

  @override
  State<MonitoringHistoryScreen> createState() => _MonitoringHistoryScreenState();
}

class _MonitoringHistoryScreenState extends State<MonitoringHistoryScreen> {
  List<Map<String, String>> historyData = [];
  double stressLevelPercentage = 0.0;

  @override
  void initState() {
    super.initState();
    _loadRealHistory();
  }

  Future<void> _loadRealHistory() async {
    final prefs = await SharedPreferences.getInstance();
    int totalDays = prefs.getInt('total_days') ?? 0;
    bool triggerDass = prefs.getBool('trigger_dass21') ?? false;

    double savedStressPercentage = prefs.getDouble('last_dass_stress_percentage') ?? (triggerDass ? 75.0 : 25.0);

    List<String> rawList = prefs.getStringList('saved_monitoring_history') ?? [];
    List<Map<String, String>> parsedList = [];

    for (String item in rawList) {
      try {
        Map<String, dynamic> decoded = jsonDecode(item);
        parsedList.add({
          'date': decoded['date'] ?? '',
          'commute': decoded['commute'] ?? '',
          'work': decoded['work'] ?? '',
        });
      } catch (_) {}
    }

    if (!mounted) return;
    setState(() {
      historyData = parsedList;
      if (totalDays == 0 && rawList.isEmpty) {
        stressLevelPercentage = 0.0;
      } else {
        stressLevelPercentage = savedStressPercentage;
      }
    });
  }

  void _showHistoryAiModal(BuildContext context, double stressLevel, int days) async {
    final prefs = await SharedPreferences.getInstance();
    final serverIp = prefs.getString('server_ip') ?? '192.168.1.15';
    final username = prefs.getString('username') ?? 'User';

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) {
        return SafeArea(
          child: Container(
            padding: const EdgeInsets.all(20),
            height: MediaQuery.of(ctx).size.height * 0.55,
            child: FutureBuilder<http.Response>(
              future: http.post(
                Uri.parse('http://$serverIp:8000/api/v1/history-recommendation'),
                headers: {'Content-Type': 'application/json'},
                body: jsonEncode({
                  'user_id': username,
                  'total_stress_percentage': stressLevel,
                  'total_days': days,
                }),
              ).timeout(const Duration(seconds: 90)),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator(color: Color(0xFF6366F1)));
                }

                String message = "Gagal memuat rekomendasi tren histori.";
                if (snapshot.hasData && snapshot.data!.statusCode == 200) {
                  final body = jsonDecode(snapshot.data!.body);
                  message = body['recommendation'] ?? message;
                }

                final bool isHighFromModal = stressLevel > 70.0;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.auto_awesome, color: Color(0xFF6366F1)),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text('Rekomendasi Tren Kumulatif AI', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF6366F1))),
                        ),
                      ],
                    ),
                    const Divider(height: 20),
                    Expanded(
                      child: SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // --- BLOK LANGKAH MENENANGKAN DIRI — hanya tampil jika stres > 70% ---
                            if (isHighFromModal) ...[
                              Container(
                                width: double.infinity,
                                padding: const EdgeInsets.all(14),
                                decoration: BoxDecoration(
                                  color: Colors.red.shade50,
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(color: Colors.red.shade200),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Icon(Icons.self_improvement, color: Colors.red.shade700, size: 20),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: Text(
                                            'Langkah Menenangkan Diri Sekarang',
                                            style: TextStyle(fontWeight: FontWeight.bold, color: Colors.red.shade800, fontSize: 14),
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 8),
                                    const Text(
                                      '• Tarik napas dalam selama 4 detik, tahan 4 detik, lalu buang perlahan 6 detik. Ulangi 5 kali.\n'
                                      '• Berhenti sejenak dari aktivitas, cari tempat tenang, minum air putih.\n'
                                      '• Hindari mengambil keputusan besar saat kondisi masih tegang.',
                                      style: TextStyle(fontSize: 13, height: 1.5),
                                    ),
                                    const SizedBox(height: 12),
                                    Container(
                                      width: double.infinity,
                                      padding: const EdgeInsets.all(10),
                                      decoration: BoxDecoration(
                                        color: Colors.red.shade700,
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: const Row(
                                        children: [
                                          Icon(Icons.local_hospital, color: Colors.white, size: 18),
                                          SizedBox(width: 8),
                                          Expanded(
                                            child: Text(
                                              'Tingkat stres kamu sudah di atas batas aman. Sangat disarankan untuk menghubungi psikiater atau tenaga profesional kesehatan mental untuk penanganan lebih lanjut.',
                                              style: TextStyle(color: Colors.white, fontSize: 12.5, height: 1.4, fontWeight: FontWeight.w600),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 16),
                            ],

                            Row(
                              children: [
                                Icon(Icons.auto_awesome, color: Colors.grey.shade600, size: 16),
                                const SizedBox(width: 6),
                                Text('Analisis Tambahan AI', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.grey.shade600)),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Text(message, style: const TextStyle(fontSize: 14, height: 1.5)),
                            const SizedBox(height: 16),
                            // --- DISCLAIMER AI WAJIB ---
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                              decoration: BoxDecoration(
                                color: const Color(0xFFFFF8E1),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: const Color(0xFFFFCC02)),
                              ),
                              child: const Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Icon(Icons.warning_amber_rounded, color: Color(0xFFF59E0B), size: 16),
                                  SizedBox(width: 8),
                                  Expanded(
                                    child: Text.rich(
                                      TextSpan(
                                        children: [
                                          TextSpan(
                                            text: 'AI dapat melakukan kesalahan. ',
                                            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Color(0xFF92400E)),
                                          ),
                                          TextSpan(
                                            text: 'Rekomendasi ini bukan pengganti diagnosis medis. Hubungi Psikolog atau tenaga kesehatan jiwa profesional untuk pertolongan yang lebih tepat.',
                                            style: TextStyle(fontSize: 12, color: Color(0xFF92400E), height: 1.4),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      height: 48,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF6366F1), foregroundColor: Colors.white),
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text('Tutup', style: TextStyle(fontWeight: FontWeight.bold)),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final double safeStressValue = stressLevelPercentage;
    final bool isHighStress = safeStressValue > 70.0;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Riwayat Monitoring Harian'),
        backgroundColor: const Color(0xFF6366F1),
        foregroundColor: Colors.white,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Card(
              elevation: 2,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Total Tingkat Stres', style: TextStyle(fontSize: 14, color: Colors.grey)),
                        const SizedBox(height: 4),
                        Text(
                          '${safeStressValue.toStringAsFixed(0)}%',
                          style: TextStyle(
                            fontSize: 28,
                            fontWeight: FontWeight.bold,
                            color: isHighStress ? Colors.red : Colors.green,
                          ),
                        ),
                      ],
                    ),
                    Icon(
                      isHighStress ? Icons.warning_amber_rounded : Icons.sentiment_satisfied_alt,
                      size: 40,
                      color: isHighStress ? Colors.red : Colors.green,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),

            if (isHighStress) ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.red.shade200),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: const [
                        Icon(Icons.report_problem, color: Colors.red, size: 20),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Tingkat stres Anda melebihi batas aman (70%).',
                            style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.red,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 10),
                            ),
                            onPressed: () {
                              Navigator.push(context, createRoute(const Dass21Screen())).then((_) => _loadRealHistory());
                            },
                            icon: const Icon(Icons.assignment_late_outlined, size: 16),
                            label: const Text('Skrining DASS-21', style: TextStyle(fontSize: 12)),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF6366F1),
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 10),
                            ),
                            onPressed: () => _showHistoryAiModal(context, safeStressValue, historyData.length),
                            icon: const Icon(Icons.auto_awesome, size: 16),
                            label: const Text('Rekomendasi AI', style: TextStyle(fontSize: 12)),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
            ],

            const Text('Rincian Per Hari', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),

            if (historyData.isEmpty)
              Card(
                elevation: 1,
                child: const Padding(
                  padding: EdgeInsets.all(20.0),
                  child: Center(
                    child: Column(
                      children: [
                        Icon(Icons.history_toggle_off, color: Color(0xFF6366F1), size: 40),
                        SizedBox(height: 8),
                        Text(
                          'Belum ada riwayat perjalanan harian yang tercatat.\nDurasi akan bertambah secara presisi real-time sesuai lokasi.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.grey, fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                ),
              )
            else
              Card(
                elevation: 1,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                clipBehavior: Clip.antiAlias,
                child: Table(
                  columnWidths: const {
                    0: FlexColumnWidth(2),
                    1: FlexColumnWidth(3),
                    2: FlexColumnWidth(2),
                  },
                  border: TableBorder(
                    horizontalInside: BorderSide(color: Color(0xFFE5E7EB), width: 1),
                    bottom: BorderSide(color: Color(0xFFE5E7EB), width: 1),
                  ),
                  children: [
                    TableRow(
                      decoration: const BoxDecoration(color: Color(0xFFEEF2FF)),
                      children: const [
                        Padding(
                          padding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                          child: Text('Tanggal', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                        ),
                        Padding(
                          padding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                          child: Text('Perjalanan', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                        ),
                        Padding(
                          padding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                          child: Text('Kerja', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                        ),
                      ],
                    ),
                    ...historyData.asMap().entries.map((entry) {
                      final i = entry.key;
                      final data = entry.value;
                      final rowColor = i.isOdd ? Colors.white : const Color(0xFFF9FAFB);
                      return TableRow(
                        decoration: BoxDecoration(color: rowColor),
                        children: [
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                            child: Text(data['date']!, style: const TextStyle(fontSize: 13)),
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                            child: Text(data['commute']!, style: const TextStyle(fontSize: 13)),
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                            child: Text(data['work']!, style: const TextStyle(fontSize: 13)),
                          ),
                        ],
                      );
                    }),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class Dass21Screen extends StatefulWidget {
  const Dass21Screen({super.key});

  @override
  State<Dass21Screen> createState() => _Dass21ScreenState();
}

class _Dass21ScreenState extends State<Dass21Screen> {
  final List<String> _questions = [
    '1. Saya merasa sulit untuk menenangan diri.',
    '2. Saya menyadari mulut saya terasa kering.',
    '3. Saya tidak dapat merasakan perasaan positif sama sekali.',
    '4. Saya mengalami kesulitan bernapas (misalnya napas cepat).',
    '5. Saya merasa sulit untuk berinisiatif melakukan sesuatu.',
    '6. Saya cenderung bereaksi berlebihan terhadap situasi.',
    '7. Saya merasa gemetar (misalnya pada tangan).',
    '8. Saya merasa menggunakan banyak energi untuk gelisah.',
    '9. Saya cemas tentang situasi yang membuat saya panik.',
    '10. Saya merasa tidak ada hal yang dapat diharapkan.',
    '11. Saya merasa gelisah dan tidak tenang.',
    '12. Saya merasa sulit untuk bersantai.',
    '13. Saya merasa sedih dan tertekan.',
    '14. Saya tidak sabar dengan gangguan terhadap apa yang saya lakukan.',
    '15. Saya merasa hampir panik.',
    '16. Saya tidak dapat merasa antusias tentang apa pun.',
    '17. Saya merasa saya tidak berharga sebagai seorang manusia.',
    '18. Saya merasa bahwa saya agak mudah tersinggung.',
    '19. Saya menyadari detak jantung saya tanpa aktivitas fisik.',
    '20. Saya merasa takut tanpa alasan yang jelas.',
    '21. Saya merasa bahwa hidup ini tidak berarti.',
  ];

  final Map<int, int> _answers = {};

  String _getLevel(int score, String type) {
    if (type == 'Depresi') {
      if (score <= 9) return 'Normal';
      if (score <= 13) return 'Ringan';
      if (score <= 20) return 'Sedang';
      if (score <= 27) return 'Berat';
      return 'Sangat Berat';
    } else if (type == 'Anxiety') {
      if (score <= 7) return 'Normal';
      if (score <= 9) return 'Ringan';
      if (score <= 14) return 'Sedang';
      if (score <= 19) return 'Berat';
      return 'Sangat Berat';
    } else {
      if (score <= 14) return 'Normal';
      if (score <= 18) return 'Ringan';
      if (score <= 25) return 'Sedang';
      if (score <= 33) return 'Berat';
      return 'Sangat Berat';
    }
  }

  void _calculateAndShowResult() async {
    if (_answers.length < 21) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Harap jawab semua 21 pertanyaan terlebih dahulu.')),
      );
      return;
    }

    List<int> stressQ = [1, 6, 8, 11, 12, 14, 18];
    List<int> anxietyQ = [2, 4, 7, 9, 15, 19, 20];
    List<int> depressionQ = [3, 5, 10, 13, 16, 17, 21];

    int rawStress = stressQ.fold(0, (sum, q) => sum + (_answers[q - 1] ?? 0));
    int rawAnxiety = anxietyQ.fold(0, (sum, q) => sum + (_answers[q - 1] ?? 0));
    int rawDepression = depressionQ.fold(0, (sum, q) => sum + (_answers[q - 1] ?? 0));

    int finalStress = rawStress * 2;
    int finalAnxiety = rawAnxiety * 2;
    int finalDepression = rawDepression * 2;

    String stressLvl = _getLevel(finalStress, 'Stres');
    String anxietyLvl = _getLevel(finalAnxiety, 'Anxiety');
    String depressionLvl = _getLevel(finalDepression, 'Depresi');

    final prefs = await SharedPreferences.getInstance();
    bool isHigh = stressLvl == 'Berat' || stressLvl == 'Sangat Berat' ||
                  anxietyLvl == 'Berat' || anxietyLvl == 'Sangat Berat' ||
                  depressionLvl == 'Berat' || depressionLvl == 'Sangat Berat';

    await prefs.setBool('trigger_dass21', isHigh);

    double calculatedPercentage = ((finalStress + finalAnxiety + finalDepression) / 126.0) * 100.0;
    if (isHigh) {
      if (calculatedPercentage < 75.0) calculatedPercentage = 75.0;
    } else {
      if (calculatedPercentage > 40.0) calculatedPercentage = 40.0;
    }
    await prefs.setDouble('last_dass_stress_percentage', calculatedPercentage);

    if (!mounted) return;
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Hasil Skrining DASS-21 & IBM BOB'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('• Depresi / Burnout: $finalDepression ($depressionLvl)'),
            const SizedBox(height: 8),
            Text('• Kecemasan (Anxiety): $finalAnxiety ($anxietyLvl)'),
            const SizedBox(height: 8),
            Text('• Stres Perjalanan: $finalStress ($stressLvl)'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              Navigator.push(
                context,
                createRoute(Dass21ResultScreen(
                  stressScore: finalStress,
                  stressLevel: stressLvl,
                  anxietyScore: finalAnxiety,
                  anxietyLevel: anxietyLvl,
                  depressionScore: finalDepression,
                  depressionLevel: depressionLvl,
                )),
              );
            },
            child: const Text('Lihat Rekomendasi AI'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF6366F1), foregroundColor: Colors.white),
            onPressed: () {
              Navigator.pop(context);
              Navigator.pop(context);
            },
            child: const Text('Selesai'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Skrining Psikologis DASS-21 & IBM BOB'), backgroundColor: const Color(0xFF6366F1), foregroundColor: Colors.white),
      resizeToAvoidBottomInset: false,
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
        child: Column(
          children: [
            Card(
              color: const Color(0xFFEEF2FF),
              elevation: 2,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              margin: const EdgeInsets.only(bottom: 16),
              child: const Padding(
                padding: EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.info_outline, color: Color(0xFF6366F1)),
                        SizedBox(width: 8),
                        Text(
                          'Petunjuk Pengisian & Skoring',
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Color(0xFF6366F1)),
                        ),
                      ],
                    ),
                    SizedBox(height: 8),
                    Text(
                      'Pilih angka (0 - 3) yang paling menggambarkan kondisi Anda selama seminggu terakhir:',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                    ),
                    SizedBox(height: 8),
                    Text('• 0 : Tidak pernah mengalami sama sekali', style: TextStyle(fontSize: 12)),
                    Text('• 1 : Kadang-kadang / Sesekali mengalami', style: TextStyle(fontSize: 12)),
                    Text('• 2 : Sering / Cukup banyak waktu mengalami', style: TextStyle(fontSize: 12)),
                    Text('• 3 : Sangat sering / Hampir setiap waktu mengalami', style: TextStyle(fontSize: 12)),
                  ],
                ),
              ),
            ),

            ...List.generate(_questions.length, (index) {
              return Card(
                margin: const EdgeInsets.only(bottom: 12),
                child: Padding(
                  padding: const EdgeInsets.all(12.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_questions[index], style: const TextStyle(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceAround,
                        children: List.generate(4, (val) {
                          return ChoiceChip(
                            label: Text('$val'),
                            selected: _answers[index] == val,
                            onSelected: (selected) {
                              if (selected) {
                                setState(() => _answers[index] = val);
                              }
                            },
                          );
                        }),
                      ),
                    ],
                  ),
                ),
              );
            }),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF6366F1), foregroundColor: Colors.white),
                onPressed: _calculateAndShowResult,
                child: const Text('Hitung Skor Psikometri'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class Dass21ResultScreen extends StatefulWidget {
  final int stressScore;
  final String stressLevel;
  final int anxietyScore;
  final String anxietyLevel;
  final int depressionScore;
  final String depressionLevel;

  const Dass21ResultScreen({
    super.key,
    required this.stressScore,
    required this.stressLevel,
    required this.anxietyScore,
    required this.anxietyLevel,
    required this.depressionScore,
    required this.depressionLevel,
  });

  @override
  State<Dass21ResultScreen> createState() => _Dass21ResultScreenState();
}

class _Dass21ResultScreenState extends State<Dass21ResultScreen> {
  bool _isLoading = true;
  String _aiRecommendation = '';

  @override
  void initState() {
    super.initState();
    _fetchAiRecommendation();
  }

  Future<void> _fetchAiRecommendation() async {
    final prefs = await SharedPreferences.getInstance();
    final serverIp = prefs.getString('server_ip') ?? '192.168.1.15';
    final username = prefs.getString('username') ?? 'User';

    try {
      final res = await http.post(
        Uri.parse('http://$serverIp:8000/api/v1/dass21-recommendation'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'user_id': username,
          'stress_score': widget.stressScore,
          'stress_level': widget.stressLevel,
          'anxiety_score': widget.anxietyScore,
          'anxiety_level': widget.anxietyLevel,
          'depression_score': widget.depressionScore,
          'depression_level': widget.depressionLevel,
        }),
      ).timeout(const Duration(seconds: 90));

      if (res.statusCode == 200) {
        final body = jsonDecode(res.body);
        setState(() {
          _aiRecommendation = body['recommendation'] ?? 'Rekomendasi berhasil dimuat.';
        });
      } else {
        setState(() {
          _aiRecommendation = "Oops anda berada diluar jaringan Server, aplikasi ini berjalan saat server dan HP di jaringan yang sama";
        });
      }
    } catch (_) {
      setState(() {
        _aiRecommendation = "Oops anda berada diluar jaringan Server, aplikasi ini berjalan saat server dan HP di jaringan yang sama";
      });
    } finally {
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    bool isHighLevel = widget.stressLevel == 'Berat' ||
        widget.stressLevel == 'Sangat Berat' ||
        widget.anxietyLevel == 'Berat' ||
        widget.anxietyLevel == 'Sangat Berat' ||
        widget.depressionLevel == 'Berat' ||
        widget.depressionLevel == 'Sangat Berat';

    return Scaffold(
      appBar: AppBar(
        title: const Text('Rekomendasi Pemulihan AI'),
        backgroundColor: const Color(0xFF6366F1),
        foregroundColor: Colors.white,
        automaticallyImplyLeading: false,
      ),
      resizeToAvoidBottomInset: false,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Card(
                elevation: 2,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Ringkasan Skor DASS-21 Anda:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                      const SizedBox(height: 8),
                      Text('• Stres: ${widget.stressScore} (${widget.stressLevel})', style: const TextStyle(fontWeight: FontWeight.w600)),
                      Text('• Kecemasan: ${widget.anxietyScore} (${widget.anxietyLevel})', style: const TextStyle(fontWeight: FontWeight.w600)),
                      Text('• Depresi: ${widget.depressionScore} (${widget.depressionLevel})', style: const TextStyle(fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              const Text('Analisis & Rekomendasi AI:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              const SizedBox(height: 8),
              Expanded(
                child: _isLoading
                    ? const Center(child: CircularProgressIndicator(color: Color(0xFF6366F1)))
                    : SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // --- Blok langkah menenangkan diri (hanya jika tingkat tinggi) ---
                            if (isHighLevel) ...[
                              Container(
                                width: double.infinity,
                                padding: const EdgeInsets.all(14),
                                decoration: BoxDecoration(
                                  color: Colors.red.shade50,
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(color: Colors.red.shade200),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Icon(Icons.self_improvement, color: Colors.red.shade700, size: 20),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: Text(
                                            'Langkah Menenangkan Diri Sekarang',
                                            style: TextStyle(fontWeight: FontWeight.bold, color: Colors.red.shade800, fontSize: 14),
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 8),
                                    const Text(
                                      '• Tarik napas dalam selama 4 detik, tahan 4 detik, lalu buang perlahan 6 detik. Ulangi 5 kali.\n'
                                      '• Berhenti sejenak dari aktivitas, cari tempat tenang, minum air putih.\n'
                                      '• Hindari mengambil keputusan besar saat kondisi masih tegang.',
                                      style: TextStyle(fontSize: 13, height: 1.5),
                                    ),
                                    const SizedBox(height: 12),
                                    Container(
                                      width: double.infinity,
                                      padding: const EdgeInsets.all(10),
                                      decoration: BoxDecoration(
                                        color: Colors.red.shade700,
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: const Row(
                                        children: [
                                          Icon(Icons.local_hospital, color: Colors.white, size: 18),
                                          SizedBox(width: 8),
                                          Expanded(
                                            child: Text(
                                              'Tingkat stres / kecemasan / depresi kamu tergolong berat. Sangat disarankan menghubungi psikiater atau psikolog klinis untuk penanganan lebih lanjut.',
                                              style: TextStyle(color: Colors.white, fontSize: 12.5, height: 1.4, fontWeight: FontWeight.w600),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 16),
                            ],

                            // --- Rekomendasi dari AI ---
                            Card(
                              color: const Color(0xFFEEF2FF),
                              elevation: 2,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                              child: Padding(
                                padding: const EdgeInsets.all(16.0),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Row(
                                      children: [
                                        Icon(Icons.auto_awesome, color: Color(0xFF6366F1)),
                                        SizedBox(width: 8),
                                        Expanded(
                                          child: Text('Analisis & Rekomendasi AI', style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF6366F1))),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 12),
                                    Text(_aiRecommendation, style: const TextStyle(fontSize: 14, height: 1.5)),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(height: 12),

                            // --- DISCLAIMER AI WAJIB ---
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                              decoration: BoxDecoration(
                                color: const Color(0xFFFFF8E1),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: const Color(0xFFFFCC02)),
                              ),
                              child: const Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Icon(Icons.warning_amber_rounded, color: Color(0xFFF59E0B), size: 16),
                                  SizedBox(width: 8),
                                  Expanded(
                                    child: Text.rich(
                                      TextSpan(
                                        children: [
                                          TextSpan(
                                            text: 'AI dapat melakukan kesalahan. ',
                                            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Color(0xFF92400E)),
                                          ),
                                          TextSpan(
                                            text: 'Hasil ini bukan pengganti diagnosis medis. Hubungi Psikolog atau tenaga kesehatan jiwa profesional untuk pertolongan yang lebih tepat.',
                                            style: TextStyle(fontSize: 12, color: Color(0xFF92400E), height: 1.4),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 16),

                            if (isHighLevel) ...[
                              SizedBox(
                                width: double.infinity,
                                height: 50,
                                child: ElevatedButton.icon(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.deepOrange.shade600,
                                    foregroundColor: Colors.white,
                                    elevation: 3,
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                  ),
                                  onPressed: () {
                                    Navigator.push(
                                      context,
                                      createRoute(const CurhatChatScreen()),
                                    );
                                  },
                                  icon: const Icon(Icons.chat_bubble_outline, size: 24),
                                  label: const Text('💬 Coba Curhat Yuk!', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                                ),
                              ),
                              const SizedBox(height: 8),
                            ],
                          ],
                        ),
                      ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF6366F1),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: () {
                    Navigator.pushAndRemoveUntil(
                      context,
                      createRoute(const DashboardScreen()),
                      (route) => false,
                    );
                  },
                  icon: const Icon(Icons.home),
                  label: const Text('Home (Ke Halaman Utama)', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class CurhatChatScreen extends StatefulWidget {
  const CurhatChatScreen({super.key});

  @override
  State<CurhatChatScreen> createState() => _CurhatChatScreenState();
}

class _CurhatChatScreenState extends State<CurhatChatScreen> {
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  List<Map<String, String>> _messages = [];
  bool _isSending = false;

  @override
  void initState() {
    super.initState();
    _loadChatHistory();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _messageController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  // Kembalikan key chat yang terikat ke username agar data tidak tercampur antar user
  Future<String> _chatKey() async {
    final prefs = await SharedPreferences.getInstance();
    final username = prefs.getString('username') ?? 'default';
    return 'saved_chat_history_$username';
  }

  Future<void> _loadChatHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final key = await _chatKey();
    final String? savedChatJson = prefs.getString(key);

    if (savedChatJson != null && savedChatJson.isNotEmpty) {
      try {
        final List rawList = jsonDecode(savedChatJson);
        // Validasi: pastikan chat yang dimuat memang milik user ini
        final username = prefs.getString('username') ?? 'default';
        setState(() {
          _messages = rawList
              .map((item) => Map<String, String>.from(item))
              .toList();
        });
        // Tambahan keamanan: jika ada pesan dengan field 'owner' yang tidak cocok, buang
        _messages.removeWhere((m) => m.containsKey('owner') && m['owner'] != username);
      } catch (_) {
        // JSON rusak / tidak valid — reset saja
        await prefs.remove(key);
        _messages = [];
      }
    }

    if (_messages.isEmpty) {
      setState(() {
        _messages = [
          {
            'sender': 'ai',
            'text': 'Halo! Aku siap mendengarkan cerita kamu. Tuliskan apa saja yang membuat pikiran atau perasaanmu terasa penuh hari ini 🌿'
          }
        ];
      });
      await _saveChatHistory();
    }
    _scrollToBottom();
  }

  Future<void> _saveChatHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final key = await _chatKey();
    await prefs.setString(key, jsonEncode(_messages));
  }

  Future<void> _clearChatHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final key = await _chatKey();
    await prefs.remove(key);
    setState(() {
      _messages = [
        {
          'sender': 'ai',
          'text': 'Obrolan telah dibersihkan. Silakan mulai cerita baru kapan saja kamu siap 🌿'
        }
      ];
    });
    await _saveChatHistory();
    _scrollToBottom();
  }

  Future<void> _sendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;

    setState(() {
      _messages.add({'sender': 'user', 'text': text});
      _isSending = true;
    });
    _messageController.clear();
    await _saveChatHistory();
    _scrollToBottom();

    final prefs = await SharedPreferences.getInstance();
    final serverIp = prefs.getString('server_ip') ?? '192.168.1.15';
    final username = prefs.getString('username') ?? 'User';

    // Kirim ke server hanya pesan user (bukan semua objek map) agar lebih ringan
    // dan tidak bocorkan metadata internal ke server
    final List<Map<String, String>> historyForServer = _messages
        .map((m) => {'role': m['sender'] == 'user' ? 'user' : 'assistant', 'content': m['text'] ?? ''})
        .toList();

    try {
      final res = await http.post(
        Uri.parse('http://$serverIp:8000/api/v1/chat-curhat'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'user_id': username,
          'message': text,
          'chat_history': historyForServer,
        }),
      ).timeout(const Duration(seconds: 120));

      if (res.statusCode == 200) {
        final body = jsonDecode(res.body);
        setState(() {
          _messages.add({'sender': 'ai', 'text': body['reply'] ?? 'Terima kasih sudah berbagi cerita.'});
        });
        await _saveChatHistory();
      } else {
        setState(() {
          _messages.add({'sender': 'ai', 'text': 'Maaf, sepertinya koneksi ke server terputus. Tetap semangat ya!'});
        });
      }
    } catch (_) {
      setState(() {
        _messages.add({'sender': 'ai', 'text': 'Maaf, jaringan lokal mengalami gangguan.'});
      });
    } finally {
      setState(() => _isSending = false);
      _scrollToBottom();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        title: const Text('Ruang Curhat AI 💬'),
        backgroundColor: const Color(0xFF6366F1),
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Hapus Obrolan',
            onPressed: () {
              showDialog(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('Hapus Obrolan?'),
                  content: const Text('Semua riwayat percakapan di ruang curhat akan dibersihkan.'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Batal')),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
                      onPressed: () {
                        Navigator.pop(ctx);
                        _clearChatHistory();
                      },
                      child: const Text('Hapus'),
                    ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView.builder(
                controller: _scrollController,
                padding: const EdgeInsets.all(16),
                itemCount: _messages.length + (_isSending ? 1 : 0),
                itemBuilder: (context, index) {
                  if (index == _messages.length && _isSending) {
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 12.0),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                          decoration: BoxDecoration(
                            color: const Color(0xFFEEF2FF),
                            borderRadius: const BorderRadius.only(
                              topLeft: Radius.circular(16),
                              topRight: Radius.circular(16),
                              bottomRight: Radius.circular(16),
                            ),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF6366F1)),
                              ),
                              SizedBox(width: 8),
                              Text(
                                'AI sedang mengetik...',
                                style: TextStyle(
                                  color: Color(0xFF6366F1),
                                  fontSize: 13,
                                  fontStyle: FontStyle.italic,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  }

                  final msg = _messages[index];
                  final isUser = msg['sender'] == 'user';
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 12.0),
                    child: Align(
                      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
                      child: Container(
                        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        decoration: BoxDecoration(
                          color: isUser ? const Color(0xFF6366F1) : const Color(0xFFEEF2FF),
                          borderRadius: BorderRadius.only(
                            topLeft: const Radius.circular(16),
                            topRight: const Radius.circular(16),
                            bottomLeft: isUser ? const Radius.circular(16) : Radius.zero,
                            bottomRight: isUser ? Radius.zero : const Radius.circular(16),
                          ),
                        ),
                        child: Text(
                          msg['text']!,
                          style: TextStyle(
                            color: isUser ? Colors.white : const Color(0xFF312E81),
                            fontSize: 14,
                            height: 1.4,
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              color: Colors.white,
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _messageController,
                      decoration: const InputDecoration(
                        hintText: 'Tuliskan curhatanmu di sini...',
                        border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(25))),
                        contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      ),
                      onSubmitted: (_) => _sendMessage(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    style: IconButton.styleFrom(backgroundColor: const Color(0xFF6366F1), foregroundColor: Colors.white),
                    icon: const Icon(Icons.send),
                    onPressed: _sendMessage,
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