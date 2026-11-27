import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:share_plus/share_plus.dart';

import '../data/app_database.dart';
import '../services/backup_service.dart';
import '../services/security_service.dart';

const Color brandGreen = Color(0xFF176B45);
const Color brandGreenDark = Color(0xFF0E5234);
const Color brandGreenSoft = Color(0xFFE8F3EC);
const Color dangerRed = Color(0xFFCE3535);
const Color accentYellow = Color(0xFFFFC845);
const Color accentYellowSoft = Color(0xFFFFF5D8);
const Color appInk = Color(0xFF17251D);

class ThemeController extends ChangeNotifier {
  ThemeMode mode = ThemeMode.system;
  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final value = prefs.getString('theme_mode') ?? 'system';
      mode = switch (value) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };
    } catch (_) {
      mode = ThemeMode.system;
    }
    notifyListeners();
  }

  Future<void> setMode(ThemeMode value) async {
    mode = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('theme_mode', switch (value) {
        ThemeMode.light => 'light',
        ThemeMode.dark => 'dark',
        _ => 'system',
      });
    } catch (_) {
      // Keep the selected appearance for this session if preferences are unavailable.
    }
  }
}

class AppLockController extends ChangeNotifier {
  bool _locked = false;
  bool _pinConfigured = false;
  bool _sessionActive = false;
  bool get isLocked => _locked;
  bool get pinConfigured => _pinConfigured;
  bool get sessionActive => _sessionActive;

  void markPinConfigured() => _pinConfigured = true;
  void markSessionActive() => _sessionActive = true;

  void lockNow() {
    if (_locked) return;
    _locked = true;
    notifyListeners();
  }

  void unlock() {
    if (!_locked) return;
    _locked = false;
    notifyListeners();
  }
}

/// Covers the whole Navigator, not only the dashboard, so pushed detail pages
/// cannot remain visible when the app returns from the background.
class AppLifecycleShield extends StatefulWidget {
  const AppLifecycleShield({super.key, required this.controller, required this.child});
  final AppLockController controller;
  final Widget child;

  @override
  State<AppLifecycleShield> createState() => _AppLifecycleShieldState();
}

class _AppLifecycleShieldState extends State<AppLifecycleShield> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if ((state == AppLifecycleState.paused || state == AppLifecycleState.hidden) &&
        widget.controller.pinConfigured && widget.controller.sessionActive) {
      widget.controller.lockNow();
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) => Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        if (widget.controller.isLocked)
          Positioned.fill(
            child: Material(
              color: Theme.of(context).scaffoldBackgroundColor,
              child: LockPage(onUnlocked: widget.controller.unlock),
            ),
          ),
      ],
    ),
  );
}

class BinThabitApp extends StatefulWidget {
  const BinThabitApp({super.key, required this.themeController});
  final ThemeController themeController;
  @override
  State<BinThabitApp> createState() => _BinThabitAppState();
}

class _BinThabitAppState extends State<BinThabitApp> {
  final AppLockController _lockController = AppLockController();

  @override
  void initState() {
    super.initState();
    unawaited(widget.themeController.load());
  }

  @override
  void dispose() {
    _lockController.dispose();
    super.dispose();
  }

  ThemeData _theme(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final surface = dark ? const Color(0xFF17231C) : Colors.white;
    final canvas = dark ? const Color(0xFF0E1711) : const Color(0xFFF5F8F5);
    final scheme = ColorScheme.fromSeed(
      seedColor: brandGreen,
      brightness: brightness,
      primary: dark ? const Color(0xFF74D09A) : brandGreen,
      onPrimary: dark ? const Color(0xFF062414) : Colors.white,
      secondary: accentYellow,
      onSecondary: const Color(0xFF352600),
      error: dangerRed,
      surface: surface,
      onSurface: dark ? const Color(0xFFEAF2EC) : appInk,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: canvas,
      visualDensity: VisualDensity.adaptivePlatformDensity,
      appBarTheme: AppBarThemeData(
        backgroundColor: canvas,
        foregroundColor: scheme.onSurface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: scheme.onSurface,
          fontSize: 19,
          fontWeight: FontWeight.w800,
        ),
        iconTheme: IconThemeData(color: scheme.onSurface),
      ),
      cardTheme: CardThemeData(
        color: surface,
        surfaceTintColor: Colors.transparent,
        elevation: dark ? 0 : 1,
        shadowColor: brandGreen.withValues(alpha: .045),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(
            color: dark ? Colors.white.withValues(alpha: .06) : const Color(0xFFE7EEE8),
          ),
        ),
        margin: EdgeInsets.zero,
      ),
      inputDecorationTheme: InputDecorationThemeData(
        filled: true,
        fillColor: dark ? const Color(0xFF1D2B23) : const Color(0xFFFAFCFA),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        hintStyle: TextStyle(color: scheme.onSurfaceVariant.withValues(alpha: .75)),
        labelStyle: TextStyle(color: scheme.onSurfaceVariant),
        prefixIconColor: scheme.primary,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: scheme.outlineVariant.withValues(alpha: .65)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: scheme.outlineVariant.withValues(alpha: .65)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: scheme.primary, width: 1.6),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: dangerRed),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: dangerRed, width: 1.5),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: brandGreen,
          foregroundColor: Colors.white,
          disabledBackgroundColor: brandGreen.withValues(alpha: .35),
          disabledForegroundColor: Colors.white70,
          minimumSize: const Size(0, 52),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: scheme.primary,
          side: BorderSide(color: scheme.primary.withValues(alpha: .28)),
          minimumSize: const Size(0, 48),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: scheme.primary,
          textStyle: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        height: 72,
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        indicatorColor: dark ? const Color(0xFF355E43) : brandGreenSoft,
        labelTextStyle: WidgetStatePropertyAll(
          TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: scheme.onSurfaceVariant),
        ),
        iconTheme: WidgetStateProperty.resolveWith<IconThemeData?>((states) {
          final selected = states.contains(WidgetState.selected);
          return IconThemeData(color: selected ? scheme.primary : scheme.onSurfaceVariant, size: 22);
        }),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: brandGreen,
        foregroundColor: Colors.white,
        elevation: 3,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: scheme.primary,
        contentPadding: const EdgeInsetsDirectional.symmetric(horizontal: 16, vertical: 4),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant.withValues(alpha: .55),
        thickness: 1,
        space: 1,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: scheme.primary),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: dark ? const Color(0xFF26372C) : appInk,
        contentTextStyle: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.themeController,
      builder: (context, _) => MaterialApp(
        title: 'بن ثابت',
        debugShowCheckedModeBanner: false,
        theme: _theme(Brightness.light),
        darkTheme: _theme(Brightness.dark),
        themeMode: widget.themeController.mode,
        locale: const Locale('ar'),
        supportedLocales: const [Locale('ar'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        builder: (context, child) => Directionality(
          textDirection: ui.TextDirection.rtl,
          child: AppLifecycleShield(
            controller: _lockController,
            child: child ?? const SizedBox.shrink(),
          ),
        ),
        home: AppGate(themeController: widget.themeController, lockController: _lockController),
      ),
    );
  }
}

class AppGate extends StatefulWidget {
  const AppGate({super.key, required this.themeController, required this.lockController});
  final ThemeController themeController;
  final AppLockController lockController;
  @override
  State<AppGate> createState() => _AppGateState();
}

class _AppGateState extends State<AppGate> {
  bool? _hasPin;
  bool _unlocked = false;
  String? _storageError;
  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    try {
      final exists = await SecurityService.instance.hasPin();
      if (exists) widget.lockController.markPinConfigured();
      if (mounted) setState(() { _hasPin = exists; _storageError = null; });
    } catch (_) {
      if (mounted) setState(() => _storageError = 'تعذر الوصول إلى التخزين الآمن على هذا الجهاز');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_storageError != null) {
      return Scaffold(body: Center(child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.security_outlined, size: 48, color: dangerRed),
          const SizedBox(height: 12),
          Text(_storageError!, textAlign: TextAlign.center),
          const SizedBox(height: 14),
          FilledButton.icon(onPressed: () { setState(() { _hasPin = null; _storageError = null; }); _check(); }, icon: const Icon(Icons.refresh_rounded), label: const Text('إعادة المحاولة')),
        ]),
      )));
    }
    if (_hasPin == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    if (!_hasPin!) {
      return SetupPinPage(onDone: () {
        widget.lockController.markPinConfigured();
        widget.lockController.markSessionActive();
        setState(() { _hasPin = true; _unlocked = true; });
      });
    }
    if (!_unlocked) return LockPage(onUnlocked: () {
      widget.lockController.markSessionActive();
      setState(() => _unlocked = true);
    });
    return MainShell(themeController: widget.themeController, lockController: widget.lockController);
  }
}

class SetupPinPage extends StatefulWidget {
  const SetupPinPage({super.key, required this.onDone});
  final VoidCallback onDone;
  @override
  State<SetupPinPage> createState() => _SetupPinPageState();
}

class _SetupPinPageState extends State<SetupPinPage> {
  final _pin = TextEditingController();
  final _confirm = TextEditingController();
  bool _saving = false;
  String? _error;
  @override
  void dispose() { _pin.dispose(); _confirm.dispose(); super.dispose(); }

  Future<void> _save() async {
    if (_pin.text.length < 6 || _pin.text != _confirm.text) {
      setState(() => _error = 'استخدم 6 أرقام على الأقل وتأكد من تطابق الرمز');
      return;
    }
    setState(() { _saving = true; _error = null; });
    try {
      await SecurityService.instance.setPin(_pin.text);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('store_name', prefs.getString('store_name') ?? 'بن ثابت');
      await prefs.setString('store_phone', prefs.getString('store_phone') ?? '772206813');
      await prefs.setString('store_address', prefs.getString('store_address') ?? 'ريدة المعارة - حضرموت - اليمن');
      await prefs.setString('store_activity', prefs.getString('store_activity') ?? 'للبلاط والسيراميك والديكورات ومنظومات الطاقة الشمسية والأدوات الصحية');
      // Initialize the encrypted database and create a first local recovery point.
      try {
        await AppDatabase.instance.database;
        await BackupService.instance.createScheduledLocalBackup();
      } catch (_) {
        // Setup must remain available; a manual backup is offered in Settings.
      }
      widget.onDone();
    } catch (e) {
      if (mounted) setState(() => _error = userError(e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(child: Center(child: SingleChildScrollView(
        padding: const EdgeInsets.all(24), child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 420), child: Column(
          children: [
            const BrandMark(size: 104),
            const SizedBox(height: 18),
            Text('مرحبًا بك في بن ثابت', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            const Text('أنشئ رمزًا لحماية حساباتك', style: TextStyle(color: Colors.grey)),
            const SizedBox(height: 26),
            TextField(controller: _pin, keyboardType: TextInputType.number, obscureText: true, maxLength: 8, inputFormatters: [FilteringTextInputFormatter.digitsOnly], decoration: const InputDecoration(labelText: 'رمز PIN', prefixIcon: Icon(Icons.lock_outline))),
            const SizedBox(height: 12),
            TextField(controller: _confirm, keyboardType: TextInputType.number, obscureText: true, maxLength: 8, inputFormatters: [FilteringTextInputFormatter.digitsOnly], decoration: const InputDecoration(labelText: 'تأكيد الرمز', prefixIcon: Icon(Icons.verified_user_outlined))),
            if (_error != null) Padding(padding: const EdgeInsets.all(8), child: Text(_error!, style: const TextStyle(color: dangerRed))),
            SizedBox(width: double.infinity, child: FilledButton(onPressed: _saving ? null : _save, child: _saving ? const CircularProgressIndicator() : const Text('حفظ وبدء الاستخدام'))),
          ],
        )),
      ))),
    );
  }
}

class LockPage extends StatefulWidget {
  const LockPage({super.key, required this.onUnlocked});
  final VoidCallback onUnlocked;
  @override
  State<LockPage> createState() => _LockPageState();
}

class _LockPageState extends State<LockPage> {
  final _pin = TextEditingController();
  bool _hasBiometric = false;
  bool _busy = false;
  String? _error;
  int _failures = 0;
  DateTime? _blockedUntil;

  @override
  void initState() {
    super.initState();
    SecurityService.instance.canUseBiometrics().then((v) { if (mounted) setState(() => _hasBiometric = v); });
  }
  @override
  void dispose() { _pin.dispose(); super.dispose(); }

  Future<void> _unlockPin() async {
    if (_busy) return;
    if (_blockedUntil != null && DateTime.now().isBefore(_blockedUntil!)) {
      setState(() => _error = 'حاول بعد قليل');
      return;
    }
    setState(() { _busy = true; _error = null; });
    try {
      final ok = await SecurityService.instance.verifyPin(_pin.text);
      if (!mounted) return;
      if (ok) {
        widget.onUnlocked();
      } else {
        _failures++;
        if (_failures >= 5) {
          _blockedUntil = DateTime.now().add(const Duration(seconds: 30));
          _failures = 0;
        }
        setState(() => _error = 'رمز القفل غير صحيح');
      }
    } catch (_) {
      if (mounted) setState(() => _error = 'تعذر التحقق من رمز القفل؛ أعد المحاولة');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _unlockBiometric() async {
    if (_busy) return;
    setState(() { _busy = true; _error = null; });
    try {
      final ok = await SecurityService.instance.authenticateBiometric();
      if (!mounted) return;
      if (ok) {
        widget.onUnlocked();
      } else {
        setState(() => _error = 'لم يتم التحقق من البصمة');
      }
    } catch (_) {
      if (mounted) setState(() => _error = 'تعذر تشغيل التحقق بالبصمة');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(child: Center(child: SingleChildScrollView(
      padding: const EdgeInsets.all(24), child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 420), child: Column(
        children: [const BrandMark(size: 100), const SizedBox(height: 18),
          Text('بن ثابت', style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8), const Text('أدخل رمز الحماية للمتابعة', style: TextStyle(color: Colors.grey)),
          const SizedBox(height: 24),
          TextField(controller: _pin, keyboardType: TextInputType.number, obscureText: true, maxLength: 8, inputFormatters: [FilteringTextInputFormatter.digitsOnly], onSubmitted: (_) => _unlockPin(), decoration: const InputDecoration(labelText: 'رمز PIN', prefixIcon: Icon(Icons.lock_outline))),
          if (_error != null) Padding(padding: const EdgeInsets.all(8), child: Text(_error!, style: const TextStyle(color: dangerRed))),
          SizedBox(width: double.infinity, child: FilledButton(onPressed: _busy ? null : _unlockPin, child: const Text('فتح التطبيق'))),
          if (_hasBiometric) ...[const SizedBox(height: 10), OutlinedButton.icon(onPressed: _busy ? null : _unlockBiometric, icon: const Icon(Icons.fingerprint), label: const Text('الدخول بالبصمة'))],
        ],
      )),
    ))),
  );
}

class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 52});
  final double size;
  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(size * .24),
    child: Container(
      width: size, height: size, color: Colors.white,
      child: Image.asset('assets/logo/ben_thabit_logo.png', fit: BoxFit.contain,
        errorBuilder: (_, __, ___) => Image.asset('assets/icon/app_icon.png', fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => Container(color: brandGreen, alignment: Alignment.center, child: Icon(Icons.menu_book_rounded, color: Colors.white, size: size * .55)))),
    ),
  );
}

class MainShell extends StatefulWidget {
  const MainShell({super.key, required this.themeController, required this.lockController});
  final ThemeController themeController;
  final AppLockController lockController;
  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _index = 0;
  int _dashboardRevision = 0;
  int _reportsRevision = 0;

  void _go(int index) {
    if (index == _index) return;
    setState(() {
      if (index == 0) _dashboardRevision++;
      if (index == 3) _reportsRevision++;
      _index = index;
    });
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      DashboardPage(key: ValueKey('dashboard-$_dashboardRevision'), onNavigate: _go),
      const ContactsPage(kind: 'customer'),
      const ContactsPage(kind: 'supplier'),
      ReportsPage(key: ValueKey('reports-$_reportsRevision')),
      SettingsPage(themeController: widget.themeController, lockController: widget.lockController),
    ];
    return Directionality(textDirection: ui.TextDirection.rtl, child: Scaffold(
      body: IndexedStack(index: _index, children: pages),
      bottomNavigationBar: NavigationBar(
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        selectedIndex: _index,
        onDestinationSelected: _go,
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home_rounded), label: 'الرئيسية'),
          NavigationDestination(icon: Icon(Icons.people_alt_outlined), selectedIcon: Icon(Icons.people_alt_rounded), label: 'العملاء'),
          NavigationDestination(icon: Icon(Icons.local_shipping_outlined), selectedIcon: Icon(Icons.local_shipping_rounded), label: 'الموردون'),
          NavigationDestination(icon: Icon(Icons.query_stats_outlined), selectedIcon: Icon(Icons.query_stats_rounded), label: 'التقارير'),
          NavigationDestination(icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings_rounded), label: 'الإعدادات'),
        ],
      ),
    ));
  }
}

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key, required this.onNavigate});
  final ValueChanged<int> onNavigate;
  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  late Future<Map<String, dynamic>> _dashboardFuture;

  @override
  void initState() {
    super.initState();
    _dashboardFuture = _load();
  }

  Future<void> _refresh() async {
    setState(() => _dashboardFuture = _load());
    await _dashboardFuture;
  }

  Future<Map<String, dynamic>> _load() async {
    final db = AppDatabase.instance;
    final customers = await db.getDashboardTotals('customer');
    final suppliers = await db.getDashboardTotals('supplier');
    final recent = await db.getRecentTransactions();
    final customerCount = await db.countParties('customer');
    final supplierCount = await db.countParties('supplier');
    return {'customers': customers, 'suppliers': suppliers, 'recent': recent, 'customerCount': customerCount, 'supplierCount': supplierCount};
  }

  @override
  Widget build(BuildContext context) {
    final prefsFuture = SharedPreferences.getInstance();
    return FutureBuilder<Map<String, dynamic>>(
      future: _dashboardFuture,
      builder: (context, snapshot) {
        final data = snapshot.data;
        return RefreshIndicator(onRefresh: _refresh, child: CustomScrollView(slivers: [
          SliverAppBar(
            pinned: true,
            title: FutureBuilder<SharedPreferences>(future: prefsFuture, builder: (_, p) => Text(p.data?.getString('store_name') ?? 'بن ثابت', style: const TextStyle(fontWeight: FontWeight.bold))),
            leading: const Padding(padding: EdgeInsets.all(10), child: BrandMark(size: 36)),
            actions: [IconButton(onPressed: () => widget.onNavigate(4), icon: const Icon(Icons.settings_outlined))],
          ),
          SliverPadding(padding: const EdgeInsets.fromLTRB(16, 8, 16, 22), sliver: SliverList(delegate: SliverChildListDelegate([
            Text(DateFormat('EEEE، d MMMM yyyy', 'ar').format(DateTime.now()), style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.grey)),
            const SizedBox(height: 12),
            FutureBuilder<SharedPreferences>(
              future: prefsFuture,
              builder: (_, prefs) => _DashboardWelcomeCard(
                storeName: prefs.data?.getString('store_name') ?? 'بن ثابت',
              ),
            ),
            const SizedBox(height: 18),
            if (snapshot.connectionState == ConnectionState.waiting && data == null)
              const SizedBox(height: 180, child: Center(child: CircularProgressIndicator()))
            else if (snapshot.hasError)
              ErrorTile(message: 'تعذر تحميل الحسابات', onRetry: _refresh)
            else ...[
              SmartHint(customerCount: data!['customerCount'] as int, supplierCount: data['supplierCount'] as int, customers: data['customers'] as Map<String, int>, suppliers: data['suppliers'] as Map<String, int>),
              const SizedBox(height: 16),
              Text('ملخص الحسابات', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
              const SizedBox(height: 10),
              LayoutBuilder(builder: (context, box) {
                final wide = box.maxWidth > 560;
                final children = [
                  BalanceSummaryCard(title: 'ديون العملاء', icon: Icons.account_balance_wallet_outlined, color: brandGreen, values: data['customers'] as Map<String, int>),
                  BalanceSummaryCard(title: 'مستحقات الموردين', icon: Icons.request_quote_outlined, color: dangerRed, values: data['suppliers'] as Map<String, int>),
                ];
                return wide ? Row(children: [Expanded(child: children[0]), const SizedBox(width: 12), Expanded(child: children[1])]) : Column(children: [children[0], const SizedBox(height: 10), children[1]]);
              }),
              const SizedBox(height: 18),
              Text('إضافة سريعة', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
              const SizedBox(height: 10),
              Wrap(spacing: 10, runSpacing: 10, children: [
                QuickAction(label: 'عميل جديد', icon: Icons.person_add_alt_rounded, onTap: () async {
                  await Navigator.push(context, MaterialPageRoute(builder: (_) => const AddPartyPage(kind: 'customer')));
                  if (mounted) await _refresh();
                }),
                QuickAction(label: 'مورد جديد', icon: Icons.local_shipping_outlined, onTap: () async {
                  await Navigator.push(context, MaterialPageRoute(builder: (_) => const AddPartyPage(kind: 'supplier')));
                  if (mounted) await _refresh();
                }),
                QuickAction(label: 'عملية عامة', icon: Icons.post_add_outlined, onTap: () async {
                  await Navigator.push(context, MaterialPageRoute(builder: (_) => const GeneralEntryPage()));
                  if (mounted) await _refresh();
                }),
              ]),
              const SizedBox(height: 20),
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text('آخر العمليات', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)), TextButton(onPressed: () => widget.onNavigate(3), child: const Text('كل التقارير'))]),
              if ((data['recent'] as List).isEmpty)
                const EmptyState(icon: Icons.receipt_long_outlined, title: 'لا توجد عمليات بعد', subtitle: 'أضف عميلًا أو موردًا لتبدأ')
              else
                ...(data['recent'] as List<Map<String, Object?>>).take(6).map((row) => TransactionTile(row: row)),
            ],
          ]))),
        ]));
      },
    );
  }
}

class _DashboardWelcomeCard extends StatelessWidget {
  const _DashboardWelcomeCard({required this.storeName});
  final String storeName;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.centerRight,
          end: Alignment.bottomLeft,
          colors: [brandGreen, brandGreenDark],
        ),
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(color: brandGreen.withValues(alpha: .16), blurRadius: 20, offset: const Offset(0, 8)),
        ],
      ),
      child: Stack(
        children: [
          Positioned(left: -26, top: -42, child: Container(
            width: 150, height: 150,
            decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: Colors.white.withValues(alpha: .08), width: 22)),
          )),
          Positioned(left: 18, bottom: -34, child: Container(
            width: 94, height: 94,
            decoration: BoxDecoration(shape: BoxShape.circle, color: accentYellow.withValues(alpha: .12)),
          )),
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(20, 20, 20, 20),
            child: Row(
              children: [
                Expanded(child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(color: Colors.white.withValues(alpha: .13), borderRadius: BorderRadius.circular(30)),
                      child: const Text('دفترك المالي اليومي', style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700)),
                    ),
                    const SizedBox(height: 12),
                    Text('أهلًا بك في $storeName', style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800)),
                    const SizedBox(height: 5),
                    Text('كل حسابات محلك في مكان واحد', style: TextStyle(color: Colors.white.withValues(alpha: .86), fontSize: 12)),
                    const SizedBox(height: 14),
                    Container(width: 42, height: 4, decoration: BoxDecoration(color: accentYellow, borderRadius: BorderRadius.circular(9))),
                  ],
                )),
                const SizedBox(width: 12),
                Container(
                  width: 66, height: 66,
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20)),
                  child: const BrandMark(size: 54),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class SmartHint extends StatelessWidget {
  const SmartHint({super.key, required this.customerCount, required this.supplierCount, required this.customers, required this.suppliers});
  final int customerCount;
  final int supplierCount;
  final Map<String, int> customers;
  final Map<String, int> suppliers;
  @override
  Widget build(BuildContext context) {
    final text = customerCount == 0 && supplierCount == 0
        ? 'ابدأ بإضافة أول عميل أو مورد.'
        : (customers.values.any((v) => v != 0) || suppliers.values.any((v) => v != 0))
            ? 'هناك أرصدة مفتوحة؛ راجع التحصيل والسداد.'
            : 'حساباتك الحالية متوازنة.';
    final isEmpty = customerCount == 0 && supplierCount == 0;
    final hintColor = isEmpty ? accentYellowSoft : brandGreenSoft;
    final iconColor = isEmpty ? const Color(0xFF9A6A00) : brandGreen;
    return Container(
      width: double.infinity,
      padding: const EdgeInsetsDirectional.fromSTEB(14, 13, 14, 13),
      decoration: BoxDecoration(
        color: Theme.of(context).brightness == Brightness.dark
            ? (isEmpty ? const Color(0xFF3A3017) : const Color(0xFF1C3827))
            : hintColor,
        borderRadius: BorderRadius.circular(17),
        border: Border.all(color: iconColor.withValues(alpha: .10)),
      ),
      child: Row(children: [
        Container(width: 34, height: 34, decoration: BoxDecoration(color: iconColor.withValues(alpha: .12), borderRadius: BorderRadius.circular(11)), child: Icon(Icons.tips_and_updates_outlined, color: iconColor, size: 19)),
        const SizedBox(width: 11),
        Expanded(child: Text(text, style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600))),
      ]),
    );
  }
}

class BalanceSummaryCard extends StatelessWidget {
  const BalanceSummaryCard({super.key, required this.title, required this.icon, required this.color, required this.values});
  final String title;
  final IconData icon;
  final Color color;
  final Map<String, int> values;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(width: 42, height: 42, decoration: BoxDecoration(color: color.withValues(alpha: .11), borderRadius: BorderRadius.circular(14)), child: Icon(icon, color: color)),
          const SizedBox(width: 11),
          Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14))),
          Container(width: 7, height: 28, decoration: BoxDecoration(color: accentYellow, borderRadius: BorderRadius.circular(8))),
        ]),
        const SizedBox(height: 16),
        CurrencyLine(currency: 'SAR', amountMinor: values['SAR'] ?? 0),
        const SizedBox(height: 9),
        CurrencyLine(currency: 'YER', amountMinor: values['YER'] ?? 0),
      ]),
    ),
  );
}

class CurrencyLine extends StatelessWidget {
  const CurrencyLine({super.key, required this.currency, required this.amountMinor});
  final String currency;
  final int amountMinor;
  @override
  Widget build(BuildContext context) => Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
    Text(currency == 'SAR' ? 'ريال سعودي' : 'ريال يمني', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.grey)),
    Text(formatMoney(amountMinor, currency), style: const TextStyle(fontWeight: FontWeight.bold)),
  ]);
}

class QuickAction extends StatelessWidget {
  const QuickAction({super.key, required this.label, required this.icon, required this.onTap});
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Material(
    color: Theme.of(context).colorScheme.surface,
    borderRadius: BorderRadius.circular(16),
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        constraints: const BoxConstraints(minWidth: 132, minHeight: 62),
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Theme.of(context).dividerColor.withValues(alpha: .35)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 38, height: 38,
            decoration: BoxDecoration(color: brandGreen.withValues(alpha: .10), borderRadius: BorderRadius.circular(12)),
            alignment: Alignment.center,
            child: Icon(icon, color: brandGreen, size: 21),
          ),
          const SizedBox(width: 9),
          Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
        ]),
      ),
    ),
  );
}

class ContactsPage extends StatefulWidget {
  const ContactsPage({super.key, required this.kind});
  final String kind;
  @override
  State<ContactsPage> createState() => _ContactsPageState();
}

class _ContactsPageState extends State<ContactsPage> {
  final _search = TextEditingController();
  Future<List<Map<String, Object?>>>? _future;
  @override
  void initState() { super.initState(); _load(); }
  @override
  void dispose() { _search.dispose(); super.dispose(); }
  void _load() => _future = AppDatabase.instance.getParties(widget.kind, search: _search.text);
  @override
  Widget build(BuildContext context) {
    final title = widget.kind == 'customer' ? 'العملاء' : 'الموردون';
    return Scaffold(
      appBar: AppBar(title: Text(title), actions: [
        IconButton(tooltip: 'الحسابات المغلقة', onPressed: () async {
          await Navigator.push(context, MaterialPageRoute(builder: (_) => ArchivedPartiesPage(kind: widget.kind)));
          if (mounted) setState(_load);
        }, icon: const Icon(Icons.inventory_2_outlined)),
      ]),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Theme.of(context).brightness == Brightness.dark ? const Color(0xFF1D3828) : brandGreenSoft,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: brandGreen.withValues(alpha: .08)),
            ),
            child: Row(children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface.withValues(alpha: .8),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(
                  widget.kind == 'customer' ? Icons.people_alt_rounded : Icons.local_shipping_outlined,
                  color: Theme.of(context).colorScheme.primary,
                  size: 25,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(widget.kind == 'customer' ? 'إدارة حسابات العملاء' : 'إدارة حسابات الموردين',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 3),
                  Text(
                    widget.kind == 'customer'
                        ? 'سجّل العملاء وتابع الديون والدفعات.'
                        : 'سجّل الموردين وتابع المستحقات والسداد.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              )),
            ]),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: TextField(
            controller: _search,
            onChanged: (_) => setState(_load),
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search_rounded),
              hintText: 'ابحث بالاسم أو رقم الحساب أو الهاتف',
              isDense: true,
            ),
          ),
        ),
        Expanded(child: FutureBuilder<List<Map<String, Object?>>>(future: _future, builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting && !snapshot.hasData) return const Center(child: CircularProgressIndicator());
          if (snapshot.hasError) return EmptyState(icon: Icons.error_outline, title: 'تعذر تحميل الحسابات', subtitle: userError(snapshot.error!));
          final parties = snapshot.data ?? [];
          if (parties.isEmpty) return EmptyState(icon: widget.kind == 'customer' ? Icons.people_outline : Icons.local_shipping_outlined, title: 'لا توجد حسابات', subtitle: 'أضف أول حساب للبدء');
          return RefreshIndicator(onRefresh: () async => setState(_load), child: ListView.separated(padding: const EdgeInsets.fromLTRB(16, 0, 16, 18), itemCount: parties.length, separatorBuilder: (_, __) => const SizedBox(height: 8), itemBuilder: (context, index) {
            final item = parties[index];
            return Card(child: ListTile(
              leading: CircleAvatar(backgroundColor: Theme.of(context).brightness == Brightness.dark ? const Color(0xFF294A35) : brandGreenSoft, child: Icon(widget.kind == 'customer' ? Icons.person_outline_rounded : Icons.storefront_outlined, color: Theme.of(context).colorScheme.primary)),
              title: Text(item['name'] as String, style: const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text((item['phone'] as String).trim().isEmpty
                  ? 'رقم الحساب ${item['account_no']}'
                  : 'رقم الحساب ${item['account_no']}  •  ${item['phone']}'),
              trailing: SizedBox(width: 112, child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                FittedBox(fit: BoxFit.scaleDown, child: Text(formatMoney(item['balance_sar'] as int? ?? 0, 'SAR'), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold))),
                FittedBox(fit: BoxFit.scaleDown, child: Text(formatMoney(item['balance_yer'] as int? ?? 0, 'YER'), style: const TextStyle(fontSize: 12, color: Colors.grey))),
              ])),
              onTap: () async { await Navigator.push(context, MaterialPageRoute(builder: (_) => ContactDetailPage(partyId: item['id'] as int))); if (mounted) setState(_load); },
            ));
          }));
        })),
      ]),
      floatingActionButton: FloatingActionButton.extended(onPressed: () async {
        await Navigator.push(context, MaterialPageRoute(builder: (_) => AddPartyPage(kind: widget.kind)));
        if (mounted) setState(_load);
      }, icon: const Icon(Icons.add), label: const Text('إضافة')),
    );
  }
}

class ArchivedPartiesPage extends StatefulWidget {
  const ArchivedPartiesPage({super.key, required this.kind});
  final String kind;
  @override
  State<ArchivedPartiesPage> createState() => _ArchivedPartiesPageState();
}

class _ArchivedPartiesPageState extends State<ArchivedPartiesPage> {
  Future<List<Map<String, Object?>>>? _future;
  @override
  void initState() { super.initState(); _load(); }
  void _load() => _future = AppDatabase.instance.getArchivedParties(widget.kind);

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('الحسابات المغلقة')),
    body: FutureBuilder<List<Map<String, Object?>>>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting && !snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return const EmptyState(icon: Icons.error_outline, title: 'تعذر تحميل الأرشيف', subtitle: '');
        }
        final rows = snapshot.data ?? [];
        if (rows.isEmpty) {
          return const EmptyState(icon: Icons.inventory_2_outlined, title: 'لا توجد حسابات مغلقة', subtitle: 'ستظهر الحسابات المغلقة هنا');
        }
        return ListView.separated(
          padding: const EdgeInsets.all(16),
          itemCount: rows.length,
          separatorBuilder: (_, __) => const SizedBox(height: 8),
          itemBuilder: (context, index) {
            final row = rows[index];
            return Card(child: ListTile(
              leading: const CircleAvatar(child: Icon(Icons.inventory_2_outlined)),
              title: Text(row['name'] as String),
              subtitle: Text('رقم الحساب ${row['account_no']}'),
              trailing: const Icon(Icons.chevron_left),
              onTap: () async {
                await Navigator.push(context, MaterialPageRoute(builder: (_) => ContactDetailPage(partyId: row['id'] as int)));
                if (mounted) setState(_load);
              },
            ));
          },
        );
      },
    ),
  );
}

class AddPartyPage extends StatefulWidget {
  const AddPartyPage({super.key, required this.kind});
  final String kind;
  @override
  State<AddPartyPage> createState() => _AddPartyPageState();
}

class _AddPartyPageState extends State<AddPartyPage> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _address = TextEditingController();
  final _notes = TextEditingController();
  bool _saving = false;
  String? _saveError;
  String? _saveErrorDetails;

  bool get _isCustomer => widget.kind == 'customer';
  String get _entityName => _isCustomer ? 'العميل' : 'المورد';

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _address.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _saving = true;
      _saveError = null;
    });

    try {
      await AppDatabase.instance.createParty(
        kind: widget.kind,
        name: _name.text,
        phone: _phone.text,
        address: _address.text,
        notes: _notes.text,
      );
      if (!mounted) return;
      showMessage(context, 'تمت إضافة $_entityName بنجاح');
      Navigator.of(context).pop(true);
    } catch (error, stackTrace) {
      debugPrint('AddPartyPage: failed to create ${widget.kind}: $error');
      debugPrintStack(stackTrace: stackTrace);
      if (mounted) {
        setState(() {
          _saveError = partySaveError(error);
          // Keep the unabridged exception and stack trace available for support.
          // The visible message remains short; the user can copy the full details.
          _saveErrorDetails = '${error.toString()}\n\n$stackTrace';
        });
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  InputDecoration _fieldDecoration(String label, IconData icon, {String? hint}) => InputDecoration(
    labelText: label,
    hintText: hint,
    prefixIcon: Icon(icon),
    counterText: '',
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text('إضافة $_entityName جديد'),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
          child: SizedBox(
            height: 54,
            child: FilledButton.icon(
              onPressed: _saving ? null : _save,
              icon: _saving
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.person_add_alt_1_rounded),
              label: Text(_saving ? 'جارٍ الحفظ...' : 'حفظ $_entityName'),
            ),
          ),
        ),
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: theme.brightness == Brightness.dark ? const Color(0xFF1D3828) : brandGreenSoft,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: brandGreen.withValues(alpha: .09)),
              ),
              child: Row(
                children: [
                  Container(
                    width: 54,
                    height: 54,
                    decoration: BoxDecoration(
                      color: colorScheme.surface.withValues(alpha: .8),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Icon(
                      _isCustomer ? Icons.person_add_alt_1_rounded : Icons.local_shipping_outlined,
                      size: 28,
                      color: colorScheme.primary,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'بيانات $_entityName',
                          style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'أدخل الاسم فقط لإضافة الحساب، وبقية البيانات اختيارية.',
                          style: theme.textTheme.bodySmall?.copyWith(color: colorScheme.onPrimaryContainer),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            Text('المعلومات الأساسية', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    TextFormField(
                      controller: _name,
                      autofocus: true,
                      maxLength: 120,
                      textCapitalization: TextCapitalization.words,
                      textInputAction: TextInputAction.next,
                      decoration: _fieldDecoration('اسم $_entityName *', Icons.badge_outlined, hint: 'اكتب الاسم الكامل'),
                      validator: (value) => (value ?? '').trim().isEmpty ? 'الاسم مطلوب لإضافة الحساب' : null,
                    ),
                    const SizedBox(height: 14),
                    TextFormField(
                      controller: _phone,
                      keyboardType: TextInputType.phone,
                      textInputAction: TextInputAction.next,
                      maxLength: 32,
                      decoration: _fieldDecoration('رقم الهاتف', Icons.phone_outlined, hint: 'اختياري'),
                    ),
                    const SizedBox(height: 14),
                    TextFormField(
                      controller: _address,
                      textInputAction: TextInputAction.next,
                      maxLength: 240,
                      decoration: _fieldDecoration('العنوان', Icons.location_on_outlined, hint: 'المنطقة أو المدينة'),
                    ),
                    const SizedBox(height: 14),
                    TextFormField(
                      controller: _notes,
                      minLines: 2,
                      maxLines: 4,
                      maxLength: 1000,
                      decoration: _fieldDecoration('ملاحظات', Icons.notes_rounded, hint: 'أي تفاصيل إضافية (اختياري)'),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Row(
                  children: [
                    Icon(Icons.info_outline_rounded, color: colorScheme.primary),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'سيُنشأ رقم الحساب تلقائيًا، ولن تحتاج إلى إدخاله بنفسك.',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (_saveError != null) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.error_outline_rounded, color: colorScheme.error),
                        const SizedBox(width: 10),
                        Expanded(child: SelectableText(_saveError!, style: TextStyle(color: colorScheme.onErrorContainer))),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: AlignmentDirectional.centerEnd,
                      child: TextButton.icon(
                        onPressed: _saveErrorDetails == null ? null : () async {
                          await Clipboard.setData(ClipboardData(text: _saveErrorDetails!));
                          if (!mounted) return;
                          showMessage(context, 'تم نسخ تفاصيل الخطأ كاملة. الصقها في المحادثة.');
                        },
                        icon: const Icon(Icons.copy_rounded, size: 18),
                        label: const Text('نسخ تفاصيل الخطأ كاملة'),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class EditPartyPage extends StatefulWidget {
  const EditPartyPage({super.key, required this.party});
  final Map<String, Object?> party;
  @override
  State<EditPartyPage> createState() => _EditPartyPageState();
}

class _EditPartyPageState extends State<EditPartyPage> {
  late final TextEditingController _name = TextEditingController(text: widget.party['name'] as String? ?? '');
  late final TextEditingController _phone = TextEditingController(text: widget.party['phone'] as String? ?? '');
  late final TextEditingController _address = TextEditingController(text: widget.party['address'] as String? ?? '');
  late final TextEditingController _notes = TextEditingController(text: widget.party['notes'] as String? ?? '');
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose(); _phone.dispose(); _address.dispose(); _notes.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await AppDatabase.instance.updateParty(
        id: widget.party['id'] as int,
        name: _name.text,
        phone: _phone.text,
        address: _address.text,
        notes: _notes.text,
      );
      if (!mounted) return;
      showMessage(context, 'تم تحديث بيانات الحساب');
      Navigator.pop(context);
    } catch (error) {
      if (mounted) showMessage(context, userError(error));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('تعديل بيانات الحساب')),
    body: ListView(padding: const EdgeInsets.all(16), children: [
      TextField(controller: _name, maxLength: 120, textCapitalization: TextCapitalization.words, decoration: const InputDecoration(labelText: 'الاسم *', prefixIcon: Icon(Icons.person_outline))),
      const SizedBox(height: 12),
      TextField(controller: _phone, maxLength: 32, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'رقم الهاتف', prefixIcon: Icon(Icons.phone_outlined))),
      const SizedBox(height: 12),
      TextField(controller: _address, maxLength: 240, decoration: const InputDecoration(labelText: 'العنوان', prefixIcon: Icon(Icons.location_on_outlined))),
      const SizedBox(height: 12),
      TextField(controller: _notes, maxLength: 1000, maxLines: 3, decoration: const InputDecoration(labelText: 'ملاحظات', prefixIcon: Icon(Icons.notes_outlined))),
      const SizedBox(height: 20),
      FilledButton.icon(onPressed: _saving ? null : _save, icon: const Icon(Icons.save_outlined), label: _saving ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('حفظ التعديلات')),
    ]),
  );
}

class ContactDetailPage extends StatefulWidget {
  const ContactDetailPage({super.key, required this.partyId});
  final int partyId;
  @override
  State<ContactDetailPage> createState() => _ContactDetailPageState();
}

class _ContactDetailPageState extends State<ContactDetailPage> {
  Map<String, Object?>? party;
  Map<String, int> balances = {'SAR': 0, 'YER': 0};
  List<Map<String, Object?>> rows = [];
  bool _loading = true;
  String? _loadError;
  @override
  void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    if (!mounted) return;
    setState(() { _loading = true; _loadError = null; });
    try {
      final loadedParty = await AppDatabase.instance.getParty(widget.partyId);
      if (loadedParty == null) {
        if (mounted) setState(() { party = null; rows = []; _loading = false; });
        return;
      }
      final loadedBalances = await AppDatabase.instance.getBalances(widget.partyId);
      final loadedTransactions = await AppDatabase.instance.getPartyTransactions(widget.partyId);
      if (mounted) setState(() {
        party = loadedParty; balances = loadedBalances; rows = loadedTransactions; _loading = false;
      });
    } catch (error) {
      if (mounted) setState(() { _loading = false; _loadError = userError(error); });
    }
  }
  Future<void> _add(String type) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => AddPartyTransactionPage(partyId: widget.partyId, type: type)));
    if (mounted) await _load();
  }
  Future<void> _editParty() async {
    if (party == null || party!['archived_at'] != null) return;
    await Navigator.push(context, MaterialPageRoute(builder: (_) => EditPartyPage(party: party!)));
    if (mounted) await _load();
  }

  Future<void> _shareStatement() async {
    final current = party;
    if (current == null) return;
    try {
      final customer = current['kind'] == 'customer';
      final buffer = StringBuffer()
        ..writeln('كشف حساب - بن ثابت')
        ..writeln('الاسم: ${current['name']}')
        ..writeln('رقم الحساب: ${current['account_no']}')
        ..writeln('النوع: ${customer ? 'عميل' : 'مورد'}')
        ..writeln('--------------------')
        ..writeln('الرصيد بالريال السعودي: ${formatMoney(balances['SAR'] ?? 0, 'SAR')}')
        ..writeln('الرصيد بالريال اليمني: ${formatMoney(balances['YER'] ?? 0, 'YER')}')
        ..writeln('--------------------')
        ..writeln('الحركات:');
      for (final row in rows.take(250)) {
        final type = switch (row['type']) {
          'charge' => customer ? 'دين على العميل' : 'مستحق للمورد',
          'payment' => customer ? 'دفعة مستلمة' : 'سداد للمورد',
          _ => row['type'].toString(),
        };
        final date = DateTime.tryParse(row['occurred_at'] as String? ?? '')?.toLocal();
        buffer.writeln(
          '${date == null ? '' : DateFormat('yyyy-MM-dd').format(date)} | $type | ${formatMoney(row['amount_minor'] as int, row['currency'] as String)}',
        );
        final note = (row['note'] as String? ?? '').trim();
        if (note.isNotEmpty) buffer.writeln('البيان: $note');
      }
      if (rows.length > 250) buffer.writeln('تم عرض آخر 250 حركة فقط.');
      buffer.writeln('--------------------');
      buffer.writeln('رقم المحل: 772206813');
      await SharePlus.instance.share(ShareParams(
        title: 'كشف حساب ${current['name']} - بن ثابت',
        text: buffer.toString(),
      ));
    } catch (error) {
      if (mounted) showMessage(context, userError(error));
    }
  }

  Future<void> _archive() async {
    final yes = await showDialog<bool>(context: context, builder: (context) => AlertDialog(title: const Text('أرشفة الحساب؟'), content: const Text('سيُنقل الحساب إلى الأرشيف مع الاحتفاظ بكامل كشفه ورصيده. لن تُحذف أي عملية.'), actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('إلغاء')), FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('إغلاق'))]));
    if (yes == true) { await AppDatabase.instance.archiveParty(widget.partyId); if (mounted) Navigator.pop(context); }
  }

  Future<void> _restoreArchived() async {
    await AppDatabase.instance.restoreParty(widget.partyId);
    if (mounted) {
      showMessage(context, 'تمت إعادة فتح الحساب');
      await _load();
    }
  }
  @override
  Widget build(BuildContext context) {
    if (_loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    if (_loadError != null) return Scaffold(appBar: AppBar(title: const Text('الحساب')), body: ErrorTile(message: _loadError!, onRetry: _load));
    if (party == null) return const Scaffold(body: EmptyState(icon: Icons.person_off_outlined, title: 'الحساب غير موجود', subtitle: ''));
    final customer = party!['kind'] == 'customer';
    final isArchived = party!['archived_at'] != null;
    return Scaffold(
      appBar: AppBar(title: Text(party!['name'] as String), actions: [
        IconButton(tooltip: 'مشاركة كشف الحساب', onPressed: _shareStatement, icon: const Icon(Icons.share_outlined)),
        PopupMenuButton<String>(
          onSelected: (value) {
            if (value == 'archive') _archive();
            if (value == 'restore') _restoreArchived();
            if (value == 'edit') _editParty();
          },
          itemBuilder: (_) => [
            if (!isArchived) const PopupMenuItem(value: 'edit', child: Text('تعديل بيانات الحساب')),
            if (isArchived) const PopupMenuItem(value: 'restore', child: Text('إعادة فتح الحساب'))
            else const PopupMenuItem(value: 'archive', child: Text('أرشفة الحساب')),
          ],
        ),
      ]),
      body: RefreshIndicator(onRefresh: _load, child: ListView(padding: const EdgeInsets.all(16), children: [
        Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('رقم الحساب ${party!['account_no']}', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.grey)),
          const SizedBox(height: 12), CurrencyLine(currency: 'SAR', amountMinor: balances['SAR'] ?? 0),
          const SizedBox(height: 10), CurrencyLine(currency: 'YER', amountMinor: balances['YER'] ?? 0),
          if ((party!['phone'] as String).isNotEmpty || (party!['address'] as String).isNotEmpty || (party!['notes'] as String).isNotEmpty) ...[
            const Divider(height: 24),
            if ((party!['phone'] as String).isNotEmpty) ListTile(contentPadding: EdgeInsets.zero, dense: true, leading: const Icon(Icons.phone_outlined), title: Text(party!['phone'] as String)),
            if ((party!['address'] as String).isNotEmpty) ListTile(contentPadding: EdgeInsets.zero, dense: true, leading: const Icon(Icons.location_on_outlined), title: Text(party!['address'] as String)),
            if ((party!['notes'] as String).isNotEmpty) ListTile(contentPadding: EdgeInsets.zero, dense: true, leading: const Icon(Icons.notes_outlined), title: Text(party!['notes'] as String)),
          ],
        ]))),
        const SizedBox(height: 14),
        if (isArchived) ...[
          const Card(child: ListTile(leading: Icon(Icons.inventory_2_outlined), title: Text('هذا الحساب في الأرشيف'), subtitle: Text('لا يمكن إضافة ديون جديدة، ويمكن تسوية الرصيد المتبقي.'))),
          if (balances.values.any((value) => value > 0))
            SizedBox(width: double.infinity, child: FilledButton.icon(
              onPressed: () => _add('payment'),
              icon: const Icon(Icons.payments_outlined),
              label: Text(customer ? 'استلام دفعة أخيرة' : 'تسجيل سداد أخير'),
            )),
        ] else Row(children: [Expanded(child: FilledButton.icon(onPressed: () => _add('charge'), icon: const Icon(Icons.add), label: Text(customer ? 'إضافة دين' : 'إضافة مستحق'))), const SizedBox(width: 10), Expanded(child: OutlinedButton.icon(onPressed: () => _add('payment'), icon: const Icon(Icons.payments_outlined), label: Text(customer ? 'استلام دفعة' : 'تسجيل سداد')))]),
        const SizedBox(height: 18), Text('كشف الحساب', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        if (rows.isEmpty) const EmptyState(icon: Icons.receipt_long_outlined, title: 'لا توجد حركات', subtitle: 'سجّل أول عملية لهذا الحساب')
        else ...rows.map((row) => TransactionTile(
          row: row,
          onEdit: isArchived ? null : () async {
            await Navigator.push(context, MaterialPageRoute(builder: (_) => AddPartyTransactionPage(
              partyId: widget.partyId,
              type: row['type'] as String,
              transaction: row,
            )));
            if (mounted) await _load();
          },
          onDelete: isArchived ? null : () async {
            final confirmed = await showDialog<bool>(
              context: context,
              builder: (dialogContext) => AlertDialog(
                title: const Text('حذف العملية؟'),
                content: const Text('سيتم إخفاؤها من الكشف مع الاحتفاظ بسجل الحذف.'),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('إلغاء')),
                  FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('حذف')),
                ],
              ),
            );
            if (confirmed != true || !mounted) return;
            try {
              await AppDatabase.instance.softDeleteTransaction(row['id'] as int);
              if (mounted) await _load();
            } catch (e) {
              if (mounted) showMessage(context, userError(e));
            }
          },
        )),
      ])),
    );
  }
}

class AddPartyTransactionPage extends StatefulWidget {
  const AddPartyTransactionPage({super.key, required this.partyId, required this.type, this.transaction});
  final int partyId;
  final String type;
  final Map<String, Object?>? transaction;
  @override
  State<AddPartyTransactionPage> createState() => _AddPartyTransactionPageState();
}

class _AddPartyTransactionPageState extends State<AddPartyTransactionPage> {
  final _amount = TextEditingController();
  final _note = TextEditingController();
  String _currency = 'SAR';
  DateTime _date = DateTime.now();
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final row = widget.transaction;
    if (row != null) {
      _amount.text = _minorToInput(row['amount_minor'] as int);
      _currency = row['currency'] as String? ?? 'SAR';
      _note.text = row['note'] as String? ?? '';
      _date = DateTime.tryParse(row['occurred_at'] as String? ?? '')?.toLocal() ?? DateTime.now();
    }
  }

  @override
  void dispose() { _amount.dispose(); _note.dispose(); super.dispose(); }
  Future<void> _save() async {
    final minor = parseMoneyMinor(_amount.text);
    if (minor == null || minor <= 0) { showMessage(context, 'أدخل مبلغًا صحيحًا'); return; }
    setState(() => _saving = true);
    try {
      if (widget.transaction == null) {
        await AppDatabase.instance.addPartyTransaction(partyId: widget.partyId, type: widget.type, amountMinor: minor, currency: _currency, occurredAt: _date, note: _note.text);
      } else {
        await AppDatabase.instance.updatePartyTransaction(
          transactionId: widget.transaction!['id'] as int,
          partyId: widget.partyId,
          type: widget.type,
          amountMinor: minor,
          currency: _currency,
          occurredAt: _date,
          note: _note.text,
        );
      }
      if (!mounted) return;
      showMessage(context, widget.transaction == null ? 'تم حفظ العملية' : 'تم تعديل العملية'); Navigator.pop(context);
    } catch (e) { if (mounted) showMessage(context, userError(e)); }
    finally { if (mounted) setState(() => _saving = false); }
  }
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.transaction != null ? 'تعديل العملية' : (widget.type == 'charge' ? 'إضافة دين' : 'تسجيل دفعة'))),
    body: ListView(padding: const EdgeInsets.all(16), children: [
      TextField(controller: _amount, keyboardType: const TextInputType.numberWithOptions(decimal: true), inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9٠-٩۰-۹.,٫٬]'))], decoration: const InputDecoration(labelText: 'المبلغ', prefixIcon: Icon(Icons.payments_outlined))),
      const SizedBox(height: 12), DropdownButtonFormField<String>(value: _currency, decoration: const InputDecoration(labelText: 'العملة'), items: const [DropdownMenuItem(value: 'SAR', child: Text('ريال سعودي (SAR)')), DropdownMenuItem(value: 'YER', child: Text('ريال يمني (YER)'))], onChanged: (v) => setState(() => _currency = v ?? 'SAR')),
      const SizedBox(height: 12), ListTile(contentPadding: EdgeInsets.zero, title: const Text('تاريخ العملية'), subtitle: Text(DateFormat('yyyy-MM-dd').format(_date)), trailing: const Icon(Icons.calendar_month_outlined), onTap: () async { final picked = await showDatePicker(context: context, initialDate: _date, firstDate: DateTime(2000), lastDate: DateTime(2100)); if (picked != null) setState(() => _date = picked); }),
      const SizedBox(height: 12), TextField(controller: _note, maxLines: 2, maxLength: 1000, decoration: const InputDecoration(labelText: 'البيان', prefixIcon: Icon(Icons.notes_rounded))),
      const SizedBox(height: 20), SizedBox(width: double.infinity, child: FilledButton(onPressed: _saving ? null : _save, child: _saving ? const CircularProgressIndicator() : Text(widget.transaction == null ? 'حفظ العملية' : 'حفظ التعديل'))),
    ]),
  );
}

class GeneralEntryPage extends StatefulWidget {
  const GeneralEntryPage({super.key, this.transaction});
  final Map<String, Object?>? transaction;
  @override
  State<GeneralEntryPage> createState() => _GeneralEntryPageState();
}

class _GeneralEntryPageState extends State<GeneralEntryPage> {
  final _amount = TextEditingController();
  final _note = TextEditingController();
  String _type = 'expense';
  String _currency = 'SAR';
  DateTime _date = DateTime.now();
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final row = widget.transaction;
    if (row != null) {
      _amount.text = _minorToInput(row['amount_minor'] as int);
      _note.text = row['note'] as String? ?? '';
      _type = row['type'] as String;
      _currency = row['currency'] as String;
      _date = DateTime.tryParse(row['occurred_at'] as String? ?? '')?.toLocal() ?? DateTime.now();
    }
  }

  @override
  void dispose() { _amount.dispose(); _note.dispose(); super.dispose(); }

  Future<void> _save() async {
    final amount = parseMoneyMinor(_amount.text);
    if (amount == null || amount <= 0) {
      showMessage(context, 'أدخل مبلغًا صحيحًا');
      return;
    }
    setState(() => _saving = true);
    try {
      if (widget.transaction == null) {
        await AppDatabase.instance.addGeneralTransaction(
          type: _type, amountMinor: amount, currency: _currency,
          occurredAt: _date, note: _note.text,
        );
      } else {
        await AppDatabase.instance.updateGeneralTransaction(
          transactionId: widget.transaction!['id'] as int,
          type: _type, amountMinor: amount, currency: _currency,
          occurredAt: _date, note: _note.text,
        );
      }
      if (!mounted) return;
      showMessage(context, widget.transaction == null ? 'تم حفظ العملية' : 'تم تعديل العملية');
      Navigator.pop(context);
    } catch (e) {
      if (mounted) showMessage(context, userError(e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.transaction == null ? 'عملية عامة' : 'تعديل عملية عامة')),
    body: ListView(padding: const EdgeInsets.all(16), children: [
      SegmentedButton<String>(
        segments: const [
          ButtonSegment(value: 'expense', icon: Icon(Icons.south_west_rounded), label: Text('مصروف')),
          ButtonSegment(value: 'income', icon: Icon(Icons.north_east_rounded), label: Text('إيراد')),
        ],
        selected: {_type},
        onSelectionChanged: (value) => setState(() => _type = value.first),
      ),
      const SizedBox(height: 16),
      TextField(
        controller: _amount,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9٠-٩۰-۹.,٫٬]'))],
        decoration: const InputDecoration(labelText: 'المبلغ', prefixIcon: Icon(Icons.payments_outlined)),
      ),
      const SizedBox(height: 12),
      DropdownButtonFormField<String>(
        value: _currency,
        decoration: const InputDecoration(labelText: 'العملة'),
        items: const [
          DropdownMenuItem(value: 'SAR', child: Text('ريال سعودي (SAR)')),
          DropdownMenuItem(value: 'YER', child: Text('ريال يمني (YER)')),
        ],
        onChanged: (value) => setState(() => _currency = value ?? 'SAR'),
      ),
      const SizedBox(height: 12),
      ListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('تاريخ العملية'),
        subtitle: Text(DateFormat('yyyy-MM-dd').format(_date)),
        trailing: const Icon(Icons.calendar_month_outlined),
        onTap: () async {
          final picked = await showDatePicker(context: context, initialDate: _date, firstDate: DateTime(2000), lastDate: DateTime(2100));
          if (picked != null && mounted) setState(() => _date = picked);
        },
      ),
      const SizedBox(height: 12),
      TextField(controller: _note, maxLines: 2, maxLength: 1000, decoration: const InputDecoration(labelText: 'البيان', prefixIcon: Icon(Icons.notes_rounded))),
      const SizedBox(height: 22),
      SizedBox(width: double.infinity, child: FilledButton.icon(
        onPressed: _saving ? null : _save,
        icon: const Icon(Icons.save_outlined),
        label: _saving ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)) : Text(widget.transaction == null ? 'حفظ العملية' : 'حفظ التعديل'),
      )),
    ]),
  );
}

class ReportsPage extends StatefulWidget {
  const ReportsPage({super.key});
  @override
  State<ReportsPage> createState() => _ReportsPageState();
}

class _ReportsPageState extends State<ReportsPage> {
  final _search = TextEditingController();
  Future<List<Map<String, Object?>>>? _future;
  String _currency = 'ALL';
  DateTime? _from;
  DateTime? _to;

  @override
  void initState() { super.initState(); _load(); }
  @override
  void dispose() { _search.dispose(); super.dispose(); }

  void _load() => _future = AppDatabase.instance.getAllTransactions(
    search: _search.text,
    currency: _currency == 'ALL' ? null : _currency,
    fromInclusive: _from,
    toExclusive: _to?.add(const Duration(days: 1)),
  );

  Future<void> _reload() async {
    setState(_load);
    await _future;
  }

  Future<void> _edit(Map<String, Object?> row) async {
    final partyId = row['party_id'] as int?;
    final page = partyId == null
        ? GeneralEntryPage(transaction: row)
        : AddPartyTransactionPage(
            partyId: partyId,
            type: row['type'] as String,
            transaction: row,
          );
    await Navigator.push(context, MaterialPageRoute(builder: (_) => page));
    if (mounted) await _reload();
  }

  Future<void> _delete(Map<String, Object?> row) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('حذف العملية؟'),
        content: const Text('ستُخفى من السجل مع الاحتفاظ بأثر الحذف.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('إلغاء')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('حذف')),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    try {
      await AppDatabase.instance.softDeleteTransaction(row['id'] as int);
      if (mounted) await _reload();
    } catch (e) {
      if (mounted) showMessage(context, userError(e));
    }
  }

  Future<void> _pickDate({required bool start}) async {
    final initial = (start ? _from : _to) ?? DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked == null || !mounted) return;
    setState(() {
      if (start) {
        _from = picked;
        if (_to != null && _to!.isBefore(picked)) _to = picked;
      } else {
        _to = picked;
        if (_from != null && _from!.isAfter(picked)) _from = picked;
      }
      _load();
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('التقارير وسجل العمليات')),
    body: Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
        child: Column(children: [
          TextField(
            controller: _search,
            onChanged: (_) => setState(_load),
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search_rounded),
              hintText: 'ابحث بالاسم أو رقم الحساب أو المبلغ أو التاريخ',
              isDense: true,
            ),
          ),
          const SizedBox(height: 10),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'ALL', label: Text('الكل')),
              ButtonSegment(value: 'SAR', label: Text('السعودي')),
              ButtonSegment(value: 'YER', label: Text('اليمني')),
            ],
            selected: {_currency},
            onSelectionChanged: (values) => setState(() { _currency = values.first; _load(); }),
          ),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: OutlinedButton.icon(
              onPressed: () => _pickDate(start: true),
              icon: const Icon(Icons.calendar_today_outlined, size: 18),
              label: Text(_from == null ? 'من تاريخ' : DateFormat('yyyy-MM-dd').format(_from!)),
            )),
            const SizedBox(width: 8),
            Expanded(child: OutlinedButton.icon(
              onPressed: () => _pickDate(start: false),
              icon: const Icon(Icons.event_outlined, size: 18),
              label: Text(_to == null ? 'إلى تاريخ' : DateFormat('yyyy-MM-dd').format(_to!)),
            )),
            IconButton(
              tooltip: 'مسح التواريخ',
              onPressed: _from == null && _to == null ? null : () => setState(() { _from = null; _to = null; _load(); }),
              icon: const Icon(Icons.filter_alt_off_outlined),
            ),
          ]),
        ]),
      ),
      Expanded(child: FutureBuilder<List<Map<String, Object?>>>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting && !snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return ErrorTile(message: 'تعذر تحميل السجل', onRetry: _reload);
          }
          final rows = snapshot.data ?? [];
          if (rows.isEmpty) {
            return const EmptyState(icon: Icons.query_stats_outlined, title: 'لا توجد عمليات', subtitle: 'غيّر البحث أو الفترة المحددة');
          }
          final counts = <String, int>{'charge': 0, 'payment': 0, 'expense': 0, 'income': 0};
          for (final row in rows) {
            final type = row['type'] as String;
            counts[type] = (counts[type] ?? 0) + 1;
          }
          return RefreshIndicator(
            onRefresh: _reload,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
              children: [
                Card(child: Padding(padding: const EdgeInsets.all(14), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('ملخص النتائج', style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 10),
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    _ReportCount(label: 'ديون', count: counts['charge'] ?? 0, color: dangerRed),
                    _ReportCount(label: 'دفعات', count: counts['payment'] ?? 0, color: brandGreen),
                    _ReportCount(label: 'مصروفات', count: counts['expense'] ?? 0, color: dangerRed),
                    _ReportCount(label: 'إيرادات', count: counts['income'] ?? 0, color: brandGreen),
                  ]),
                ]))),
                const SizedBox(height: 10),
                ...rows.map((row) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: TransactionTile(
                    row: row,
                    onEdit: row['party_archived_at'] != null ? null : () => _edit(row),
                    onDelete: row['party_archived_at'] != null ? null : () => _delete(row),
                  ),
                )),
              ],
            ),
          );
        },
      )),
    ]),
  );
}

class _ReportCount extends StatelessWidget {
  const _ReportCount({required this.label, required this.count, required this.color});
  final String label;
  final int count;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
    decoration: BoxDecoration(color: color.withValues(alpha: .10), borderRadius: BorderRadius.circular(12)),
    child: Text('$label: $count', style: TextStyle(color: color, fontWeight: FontWeight.w600, fontSize: 12)),
  );
}

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.themeController, required this.lockController});
  final ThemeController themeController;
  final AppLockController lockController;

  Future<String?> _passwordDialog(
    BuildContext context, {
    required String title,
    bool confirmPassword = false,
  }) async {
    final passwordController = TextEditingController();
    final confirmController = TextEditingController();
    String? validationMessage;
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: Text(title),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              controller: passwordController,
              obscureText: true,
              enableSuggestions: false,
              autocorrect: false,
              textCapitalization: TextCapitalization.none,
              maxLength: 128,
              textInputAction: confirmPassword ? TextInputAction.next : TextInputAction.done,
              decoration: const InputDecoration(labelText: 'كلمة المرور', helperText: 'من 12 إلى 128 حرفًا'),
            ),
            if (confirmPassword) ...[
              const SizedBox(height: 12),
              TextField(
                controller: confirmController,
                obscureText: true,
                enableSuggestions: false,
                autocorrect: false,
                textCapitalization: TextCapitalization.none,
                maxLength: 128,
                textInputAction: TextInputAction.done,
                decoration: const InputDecoration(labelText: 'تأكيد كلمة المرور'),
              ),
            ],
            if (validationMessage != null) ...[
              const SizedBox(height: 8),
              Align(alignment: AlignmentDirectional.centerStart, child: Text(validationMessage!, style: const TextStyle(color: dangerRed))),
            ],
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('إلغاء')),
            FilledButton(
              onPressed: () {
                final password = passwordController.text;
                if (password.length < 12 || password.length > 128) {
                  setDialogState(() => validationMessage = 'استخدم عبارة مرور من 12 إلى 128 حرفًا');
                  return;
                }
                if (confirmPassword && password != confirmController.text) {
                  setDialogState(() => validationMessage = 'كلمتا المرور غير متطابقتين');
                  return;
                }
                Navigator.pop(dialogContext, password);
              },
              child: const Text('متابعة'),
            ),
          ],
        ),
      ),
    );
    passwordController.dispose();
    confirmController.dispose();
    return result;
  }

  Future<void> _shareBackup(BuildContext context) async {
    final password = await _passwordDialog(context, title: 'تشفير النسخة الاحتياطية', confirmPassword: true);
    if (password == null || !context.mounted) return;
    try { await BackupService.instance.sharePortableBackup(password); }
    catch (e) { if (context.mounted) showMessage(context, userError(e)); }
  }

  Future<void> _restore(BuildContext context) async {
    final password = await _passwordDialog(context, title: 'استعادة نسخة احتياطية');
    if (password == null || !context.mounted) return;
    final confirm = await showDialog<bool>(context: context, builder: (context) => AlertDialog(title: const Text('استعادة البيانات'), content: const Text('سيتم استبدال قاعدة البيانات الحالية بالنسخة المحددة.'), actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('إلغاء')), FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('استعادة'))]));
    if (confirm != true || !context.mounted) return;
    try { final restored = await BackupService.instance.restoreFromPicker(password); if (context.mounted && restored) showMessage(context, 'تمت الاستعادة بنجاح'); }
    catch (e) { if (context.mounted) showMessage(context, userError(e)); }
  }

  @override
  Widget build(BuildContext context) => Scaffold(appBar: AppBar(title: const Text('الإعدادات')), body: ListView(padding: const EdgeInsets.all(16), children: [
    _SettingsGroup(title: 'المحل', children: [
      _SettingsItem(icon: Icons.store_outlined, title: 'بيانات المحل', subtitle: 'الاسم والهاتف والعنوان', onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const StoreProfilePage()))),
      _SettingsItem(icon: Icons.currency_exchange_rounded, title: 'العملات', subtitle: 'الريال السعودي والريال اليمني', onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const CurrencyInfoPage()))),
    ]),
    const SizedBox(height: 12),
    _SettingsGroup(title: 'المظهر', children: [
      Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8), child: SegmentedButton<ThemeMode>(segments: const [ButtonSegment(value: ThemeMode.light, icon: Icon(Icons.light_mode_outlined), label: Text('نهاري')), ButtonSegment(value: ThemeMode.dark, icon: Icon(Icons.dark_mode_outlined), label: Text('ليلي')), ButtonSegment(value: ThemeMode.system, icon: Icon(Icons.settings_suggest_outlined), label: Text('تلقائي'))], selected: {themeController.mode}, onSelectionChanged: (v) => themeController.setMode(v.first))),
    ]),
    const SizedBox(height: 12),
    _SettingsGroup(title: 'الحماية والنسخ', children: [
      _SettingsItem(icon: Icons.lock_outline, title: 'قفل التطبيق الآن', subtitle: 'تأمين جميع الشاشات فورًا', onTap: lockController.lockNow),
      _SettingsItem(icon: Icons.password_rounded, title: 'تغيير رمز PIN', subtitle: 'تحديث رمز الحماية', onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ChangePinPage()))),
      _SettingsItem(icon: Icons.cloud_upload_outlined, title: 'نسخ احتياطي مشفر', subtitle: 'مشاركة عبر واتساب أو Drive', onTap: () => _shareBackup(context)),
      _SettingsItem(icon: Icons.settings_backup_restore_outlined, title: 'استعادة نسخة', subtitle: 'استعادة بياناتك من ملف مشفر', onTap: () => _restore(context)),
      _SettingsItem(icon: Icons.schedule, title: 'النسخ الأسبوعي', subtitle: 'نسخة محلية مشفرة كل 7 أيام', onTap: () async { try { await BackupService.instance.createScheduledLocalBackup(); if (context.mounted) showMessage(context, 'تم إنشاء نسخة محلية مشفرة الآن'); } catch (e) { if (context.mounted) showMessage(context, userError(e)); } }),
      _SettingsItem(icon: Icons.folder_open_outlined, title: 'استعادة آخر نسخة أسبوعية', subtitle: 'النسخة المشفرة المحفوظة تلقائيًا', onTap: () async { final yes = await showDialog<bool>(context: context, builder: (context) => AlertDialog(title: const Text('استعادة نسخة محلية'), content: const Text('سيتم استبدال البيانات الحالية.'), actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('إلغاء')), FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('متابعة'))])); if (yes != true) return; try { await BackupService.instance.restoreLatestLocalBackup(); if (context.mounted) showMessage(context, 'تمت الاستعادة'); } catch (e) { if (context.mounted) showMessage(context, userError(e)); } }),
    ]),
    const SizedBox(height: 12),
    _SettingsGroup(title: 'عن التطبيق', children: [
      _SettingsItem(icon: Icons.info_outline_rounded, title: 'حقوق التطبيق', subtitle: 'المهندس عبد العزيز عوض بن ثابت', onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const RightsPage()))),
    ]),
    const SizedBox(height: 18),
    const Center(child: Text('بن ثابت • إصدار 1.0.2', style: TextStyle(color: Colors.grey, fontSize: 12))),
  ]));
}

class _SettingsGroup extends StatelessWidget {
  const _SettingsGroup({required this.title, required this.children});
  final String title;
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Padding(padding: const EdgeInsets.only(bottom: 8, right: 4), child: Text(title, style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold, color: brandGreen))), Card(child: Column(children: children))]);
}
class _SettingsItem extends StatelessWidget {
  const _SettingsItem({required this.icon, required this.title, required this.subtitle, required this.onTap});
  final IconData icon; final String title; final String subtitle; final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => ListTile(leading: Icon(icon, color: brandGreen), title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)), subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis), trailing: const Icon(Icons.chevron_left), onTap: onTap);
}

class ChangePinPage extends StatefulWidget {
  const ChangePinPage({super.key});
  @override
  State<ChangePinPage> createState() => _ChangePinPageState();
}

class _ChangePinPageState extends State<ChangePinPage> {
  final _oldPin = TextEditingController();
  final _newPin = TextEditingController();
  final _confirmPin = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _oldPin.dispose();
    _newPin.dispose();
    _confirmPin.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_newPin.text != _confirmPin.text) {
      setState(() => _error = 'رمز الحماية الجديد غير متطابق');
      return;
    }
    setState(() { _saving = true; _error = null; });
    try {
      final verified = await SecurityService.instance.verifyPin(_oldPin.text);
      if (!verified) {
        if (mounted) setState(() => _error = 'رمز الحماية الحالي غير صحيح');
        return;
      }
      await SecurityService.instance.setPin(_newPin.text);
      if (!mounted) return;
      showMessage(context, 'تم تحديث رمز الحماية');
      Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => _error = userError(e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _pinField(TextEditingController controller, String label) => TextField(
    controller: controller,
    obscureText: true,
    keyboardType: TextInputType.number,
    maxLength: 8,
    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
    decoration: InputDecoration(labelText: label, prefixIcon: const Icon(Icons.lock_outline_rounded)),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('تغيير رمز PIN')),
    body: ListView(padding: const EdgeInsets.all(16), children: [
      _pinField(_oldPin, 'رمز PIN الحالي'),
      const SizedBox(height: 12),
      _pinField(_newPin, 'رمز PIN الجديد'),
      const SizedBox(height: 12),
      _pinField(_confirmPin, 'تأكيد الرمز الجديد'),
      if (_error != null) Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text(_error!, style: const TextStyle(color: dangerRed))),
      const SizedBox(height: 14),
      FilledButton.icon(
        onPressed: _saving ? null : _save,
        icon: const Icon(Icons.verified_user_outlined),
        label: _saving ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('حفظ رمز الحماية'),
      ),
    ]),
  );
}

class StoreProfilePage extends StatefulWidget {
  const StoreProfilePage({super.key});
  @override
  State<StoreProfilePage> createState() => _StoreProfilePageState();
}
class _StoreProfilePageState extends State<StoreProfilePage> {
  final _name = TextEditingController(); final _phone = TextEditingController(); final _address = TextEditingController(); final _activity = TextEditingController();
  @override
  void initState() { super.initState(); _load(); }
  Future<void> _load() async { final p = await SharedPreferences.getInstance(); if (!mounted) return; _name.text = p.getString('store_name') ?? 'بن ثابت'; _phone.text = p.getString('store_phone') ?? '772206813'; _address.text = p.getString('store_address') ?? 'ريدة المعارة - حضرموت - اليمن'; _activity.text = p.getString('store_activity') ?? 'للبلاط والسيراميك والديكورات ومنظومات الطاقة الشمسية والأدوات الصحية'; }
  @override
  void dispose() { _name.dispose(); _phone.dispose(); _address.dispose(); _activity.dispose(); super.dispose(); }
  Future<void> _save() async {
    if (_name.text.trim().isEmpty) { showMessage(context, 'اسم المحل مطلوب'); return; }
    if (_name.text.trim().length > 120 || _phone.text.trim().length > 32 ||
        _address.text.trim().length > 240 || _activity.text.trim().length > 300) {
      showMessage(context, 'تجاوز أحد الحقول الحد المسموح'); return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('store_name', _name.text.trim());
    await prefs.setString('store_phone', _phone.text.trim());
    await prefs.setString('store_address', _address.text.trim());
    await prefs.setString('store_activity', _activity.text.trim());
    if (mounted) { showMessage(context, 'تم حفظ بيانات المحل'); Navigator.pop(context); }
  }
  @override
  Widget build(BuildContext context) => Scaffold(appBar: AppBar(title: const Text('بيانات المحل')), body: ListView(padding: const EdgeInsets.all(16), children: [
    TextField(controller: _name, maxLength: 120, decoration: const InputDecoration(labelText: 'اسم المحل')),
    const SizedBox(height: 12), TextField(controller: _phone, maxLength: 32, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'رقم المحل')),
    const SizedBox(height: 12), TextField(controller: _address, maxLength: 240, decoration: const InputDecoration(labelText: 'العنوان')),
    const SizedBox(height: 12), TextField(controller: _activity, maxLength: 300, decoration: const InputDecoration(labelText: 'النشاط')),
    const SizedBox(height: 20), FilledButton(onPressed: _save, child: const Text('حفظ')),
  ]));
}

class CurrencyInfoPage extends StatelessWidget {
  const CurrencyInfoPage({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(appBar: AppBar(title: const Text('العملات')), body: ListView(padding: const EdgeInsets.all(16), children: const [
    Card(child: ListTile(leading: CircleAvatar(child: Text('ر.س')), title: Text('الريال السعودي'), subtitle: Text('SAR • خانتان عشريتان'))),
    SizedBox(height: 10), Card(child: ListTile(leading: CircleAvatar(child: Text('ر.ي')), title: Text('الريال اليمني'), subtitle: Text('YER • خانتان عشريتان'))),
    SizedBox(height: 12), Text('الأرصدة منفصلة. سجّل كل حركة بعملتها الأصلية؛ تحويل العملات غير متاح في هذا الإصدار.', style: TextStyle(color: Colors.grey)),
  ]));
}

class RightsPage extends StatelessWidget {
  const RightsPage({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('حقوق التطبيق')),
    body: SafeArea(child: Center(child: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 460), child: Column(mainAxisSize: MainAxisSize.min, children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: Image.asset('assets/logo/ben_thabit_logo.png', width: 172, height: 172, fit: BoxFit.cover),
        ),
        const SizedBox(height: 18),
        Text('بن ثابت', style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold, color: brandGreen)),
        const SizedBox(height: 22),
        const Text('تصميم وتطوير', style: TextStyle(color: Colors.grey)),
        const SizedBox(height: 6),
        const Text('المهندس عبد العزيز عوض بن ثابت', textAlign: TextAlign.center, style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 10),
        const SelectableText('للتواصل: 779439629'),
        const SizedBox(height: 24),
        const Text('جميع الحقوق محفوظة © 2026', style: TextStyle(color: Colors.grey)),
      ])),
    ))),
  );
}

class TransactionTile extends StatelessWidget {
  const TransactionTile({super.key, required this.row, this.onDelete, this.onEdit});
  final Map<String, Object?> row;
  final VoidCallback? onDelete;
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    final type = row['type'] as String;
    final increasesBalance = type == 'charge' || type == 'income';
    final partyKind = row['party_kind'] as String?;
    // Positive customer receivables and supplier settlements are green;
    // supplier payables and outgoing expenses are red.
    final favorable = type == 'income' ||
        (partyKind == 'customer' && type == 'charge') ||
        (partyKind == 'supplier' && type == 'payment');
    final title = switch (type) {
      'charge' => partyKind == 'supplier' ? 'مستحق للمورد' : 'دين على العميل',
      'payment' => partyKind == 'supplier' ? 'سداد للمورد' : 'دفعة من العميل',
      'expense' => 'مصروف',
      'income' => 'إيراد',
      _ => 'عملية',
    };
    final rawDate = DateTime.tryParse(row['occurred_at'] as String? ?? '')?.toLocal();
    final amountText = '${increasesBalance ? '+' : '−'}${formatMoney(row['amount_minor'] as int, row['currency'] as String)}';
    return Card(
      child: ListTile(
        contentPadding: const EdgeInsetsDirectional.only(start: 12, end: 4, top: 2, bottom: 2),
        leading: Container(
          width: 40, height: 40,
          decoration: BoxDecoration(
            color: (favorable ? brandGreen : dangerRed).withValues(alpha: .10),
            borderRadius: BorderRadius.circular(12),
          ),
          alignment: Alignment.center,
          child: Icon(
            switch (type) {
              'charge' => partyKind == 'supplier' ? Icons.shopping_bag_outlined : Icons.receipt_long_outlined,
              'payment' => Icons.payments_outlined,
              'expense' => Icons.trending_down_rounded,
              'income' => Icons.trending_up_rounded,
              _ => Icons.receipt_long_outlined,
            },
            color: favorable ? brandGreen : dangerRed,
            size: 21,
          ),
        ),
        title: Text(
          (row['party_name'] as String?)?.isNotEmpty == true ? row['party_name'] as String : title,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text('${row['note'] ?? title} • ${rawDate == null ? '' : DateFormat('yyyy-MM-dd').format(rawDate)}', maxLines: 2, overflow: TextOverflow.ellipsis),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 118),
            child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
              FittedBox(fit: BoxFit.scaleDown, child: Text(amountText, style: TextStyle(color: favorable ? brandGreen : dangerRed, fontWeight: FontWeight.bold, fontSize: 12))),
              Text(row['currency'] as String, style: const TextStyle(color: Colors.grey, fontSize: 11)),
            ]),
          ),
          if (onEdit != null || onDelete != null)
            PopupMenuButton<String>(
              tooltip: 'خيارات العملية',
              onSelected: (value) {
                if (value == 'edit') onEdit?.call();
                if (value == 'delete') onDelete?.call();
              },
              itemBuilder: (_) => [
                if (onEdit != null) const PopupMenuItem(value: 'edit', child: ListTile(leading: Icon(Icons.edit_outlined), title: Text('تعديل'), dense: true)),
                if (onDelete != null) const PopupMenuItem(value: 'delete', child: ListTile(leading: Icon(Icons.delete_outline), title: Text('حذف'), dense: true)),
              ],
            ),
        ]),
      ),
    );
  }
}


class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, required this.subtitle});
  final IconData icon; final String title; final String subtitle;
  @override
  Widget build(BuildContext context) => Padding(padding: const EdgeInsets.all(28), child: Column(mainAxisSize: MainAxisSize.min, children: [Icon(icon, size: 44, color: Colors.grey), const SizedBox(height: 12), Text(title, style: const TextStyle(fontWeight: FontWeight.bold)), if (subtitle.isNotEmpty) ...[const SizedBox(height: 4), Text(subtitle, textAlign: TextAlign.center, style: const TextStyle(color: Colors.grey))]]));
}
class ErrorTile extends StatelessWidget {
  const ErrorTile({super.key, required this.message, required this.onRetry});
  final String message; final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) => Column(children: [Text(message), TextButton(onPressed: onRetry, child: const Text('إعادة المحاولة'))]);
}

void showMessage(BuildContext context, String message) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
String partySaveError(Object error) {
  final details = error.toString();
  if (details.contains('database is locked') || details.contains('database table is locked')) {
    return 'قاعدة البيانات مشغولة الآن. انتظر قليلًا ثم حاول مرة أخرى.';
  }
  if (details.contains('UNIQUE constraint failed: parties.account_no')) {
    return 'حدث تعارض في رقم الحساب. أعد المحاولة؛ سيُعاد احتساب الرقم تلقائيًا.';
  }
  if (details.contains('no such table: parties')) {
    return 'جدول الحسابات غير موجود في قاعدة البيانات. لا تمسح بيانات التطبيق؛ أرسل تقرير الخطأ للدعم.';
  }
  if (details.contains('operation.lock') || details.contains('يتم تجهيز نسخة')) {
    return 'هناك عملية نسخ احتياطي أو استعادة تعمل الآن. انتظر قليلًا ثم حاول.';
  }
  final technicalDetails = details.length > 220 ? '${details.substring(0, 220)}…' : details;
  return 'لم يتم حفظ الحساب. سبب الخطأ: $technicalDetails';
}

String userError(Object error) {
  final text = error.toString();
  if (text.contains('no such table: app_meta')) return 'قاعدة بيانات إصدار سابق. حدّث التطبيق إلى النسخة الجديدة ثم افتحه مجددًا.';
  if (text.contains('database is locked') || text.contains('database table is locked')) return 'قاعدة البيانات مشغولة الآن. انتظر قليلًا ثم حاول مرة أخرى.';
  if (text.contains('UNIQUE constraint failed: parties.account_no')) return 'تعذر إنشاء رقم الحساب. أغلق التطبيق وافتحه مجددًا ثم أعد المحاولة.';
  if (text.contains('المبلغ أكبر') || text.contains('payment exceeds outstanding balance')) return 'المبلغ أكبر من الرصيد المتبقي بهذه العملة';
  if (text.contains('operation would make')) return 'لا يمكن تنفيذ العملية لأنها ستجعل رصيد الحساب سالبًا.';
  if (text.contains('لا يمكن حذف هذا الدين')) return 'لا يمكن حذف الدين لارتباطه بمدفوعات؛ راجع الكشف أولًا.';
  if (text.contains('إجمالي السداد')) return 'لا يمكن أن يصبح رصيد الحساب سالبًا بعد التعديل.';
  if (text.contains('نسخ أو استعادة') || text.contains('نسخة احتياطية قيد') || text.contains('تجهيز نسخة')) return 'هناك عملية نسخ أو استعادة تعمل الآن؛ حاول بعد لحظات.';
  if (text.contains('جاري النسخ')) return 'النسخ الاحتياطي قيد التنفيذ؛ حاول بعد لحظات.';
  if (text.contains('الحساب مؤرشف')) return 'هذا الحساب في الأرشيف؛ يمكنك تسجيل سداد الرصيد فقط.';
  if (text.contains('نسخة') || text.contains('كلمة المرور')) return text.replaceFirst('FormatException: ', '').replaceFirst('Bad state: ', '');
  if (text.contains('ArgumentError')) return text.replaceFirst('Invalid argument(s): ', '');
  return 'تعذر تنفيذ العملية. تحقق من البيانات وحاول مجددًا.';
}


String _minorToInput(int minor) {
  final value = BigInt.from(minor).abs();
  final whole = value ~/ BigInt.from(100);
  final fraction = (value % BigInt.from(100)).toString().padLeft(2, '0');
  return '${minor < 0 ? '-' : ''}$whole.$fraction';
}

int? parseMoneyMinor(String input) {
  var value = input.trim()
      .replaceAll('٬', ',')
      .replaceAll('٫', '.')
      .replaceAll('٠', '0').replaceAll('١', '1').replaceAll('٢', '2')
      .replaceAll('٣', '3').replaceAll('٤', '4').replaceAll('٥', '5')
      .replaceAll('٦', '6').replaceAll('٧', '7').replaceAll('٨', '8')
      .replaceAll('٩', '9')
      .replaceAll('۰', '0').replaceAll('۱', '1').replaceAll('۲', '2')
      .replaceAll('۳', '3').replaceAll('۴', '4').replaceAll('۵', '5')
      .replaceAll('۶', '6').replaceAll('۷', '7').replaceAll('۸', '8')
      .replaceAll('۹', '9');

  // Commas are accepted only as valid three-digit group separators.
  final match = RegExp(r'^(\d+|\d{1,3}(?:,\d{3})+)(?:\.(\d{1,2}))?$').firstMatch(value);
  if (match == null) return null;
  final wholeText = match.group(1)!.replaceAll(',', '');
  final whole = BigInt.tryParse(wholeText);
  if (whole == null) return null;
  final fraction = (match.group(2) ?? '').padRight(2, '0');
  final fractionValue = BigInt.tryParse(fraction.isEmpty ? '00' : fraction);
  if (fractionValue == null) return null;

  // SQLite INTEGER is a signed 64-bit value; reject overflow before conversion.
  final maxMinor = BigInt.from(0x7fffffffffffffff);
  final result = whole * BigInt.from(100) + fractionValue;
  if (result > maxMinor) return null;
  return result.toInt();
}

String formatMoney(int minor, String currency) {
  // Format with integer arithmetic to avoid precision loss from double division.
  final absolute = BigInt.from(minor).abs();
  final whole = absolute ~/ BigInt.from(100);
  final fraction = (absolute % BigInt.from(100)).toString().padLeft(2, '0');
  final groupedWhole = NumberFormat('#,##0', 'en_US').format(whole.toInt());
  final sign = minor < 0 ? '−' : '';
  final symbol = currency == 'SAR' ? 'ر.س' : 'ر.ي';
  return '$sign$groupedWhole.$fraction $symbol';
}
