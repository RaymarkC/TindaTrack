import 'dart:async';
import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'firebase_options.dart'; // created by "flutterfire configure"

final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
    FlutterLocalNotificationsPlugin();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  await _initNotifications();
  await appState.init();
  runApp(const TindaTrackApp());
}

Future<void> _initNotifications() async {
  const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
  const iosSettings = DarwinInitializationSettings();
  const initSettings = InitializationSettings(
    android: androidSettings,
    iOS: iosSettings,
  );

  await flutterLocalNotificationsPlugin.initialize(initSettings);

  // Request Android 13+ permission
  final androidPlugin = flutterLocalNotificationsPlugin
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
  await androidPlugin?.requestNotificationsPermission();
}

Future<void> showLowStockNotification(String itemName, int remainingQty) async {
  const androidDetails = AndroidNotificationDetails(
    'low_stock_channel',
    'Low Stock Alerts',
    channelDescription: 'Notifications for low stock items in TindaTrack',
    importance: Importance.high,
    priority: Priority.high,
  );
  const notificationDetails = NotificationDetails(
    android: androidDetails,
    iOS: DarwinNotificationDetails(),
  );

  await flutterLocalNotificationsPlugin.show(
    DateTime.now().millisecondsSinceEpoch ~/ 1000,
    '⚠️ Low Stock Alert!',
    '"$itemName" is running low! Only $remainingQty pcs left.',
    notificationDetails,
  );
}

// ---------------------------------------------------------------------------
// DATE HELPERS
// ---------------------------------------------------------------------------

const List<String> _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

String fmtDate(DateTime d) => '${_months[d.month - 1]} ${d.day}, ${d.year}';

String fmtTime(DateTime d) {
  final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
  final m = d.minute.toString().padLeft(2, '0');
  return '$h:$m ${d.hour < 12 ? 'AM' : 'PM'}';
}

String fmtDateTime(DateTime d) => '${fmtDate(d)} · ${fmtTime(d)}';

bool sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

String money(double v) => '₱${v.toStringAsFixed(v % 1 == 0 ? 0 : 2)}';

// ---------------------------------------------------------------------------
// DATA MODELS
// ---------------------------------------------------------------------------

class Item {
  Item({
    required this.id,
    required this.name,
    required this.qty,
    required this.price,
    DateTime? added,
    DateTime? updated,
  })  : added = added ?? DateTime.now(),
        updated = updated ?? added ?? DateTime.now();

  final String id;
  String name;
  int qty;
  double price;
  final DateTime added;
  DateTime updated;

  Map<String, dynamic> toMap() => {
        'name': name,
        'qty': qty,
        'price': price,
        'added': Timestamp.fromDate(added),
        'updated': Timestamp.fromDate(updated),
      };

  factory Item.fromDoc(QueryDocumentSnapshot<Map<String, dynamic>> d) {
    final j = d.data();
    final added = (j['added'] as Timestamp?)?.toDate();
    return Item(
      id: d.id,
      name: j['name'] as String? ?? '',
      qty: (j['qty'] as num?)?.toInt() ?? 0,
      price: (j['price'] as num?)?.toDouble() ?? 0,
      added: added,
      updated: (j['updated'] as Timestamp?)?.toDate() ?? added,
    );
  }
}

enum LogType { newItem, stockIn, stockOut, removed }

class LogEntry {
  LogEntry({
    required this.date,
    required this.itemId,
    required this.itemName,
    required this.type,
    required this.qty,
    required this.price,
  });

  final DateTime date;
  final String itemId;
  final String itemName;
  final LogType type;
  final int qty;
  final double price;

  Map<String, dynamic> toMap() => {
        'date': Timestamp.fromDate(date),
        'itemId': itemId,
        'itemName': itemName,
        'type': type.name,
        'qty': qty,
        'price': price,
      };

  factory LogEntry.fromDoc(QueryDocumentSnapshot<Map<String, dynamic>> d) {
    final j = d.data();
    return LogEntry(
      date: (j['date'] as Timestamp?)?.toDate() ?? DateTime.now(),
      itemId: j['itemId'] as String? ?? '',
      itemName: j['itemName'] as String? ?? '',
      type: LogType.values.firstWhere(
        (t) => t.name == j['type'],
        orElse: () => LogType.stockOut,
      ),
      qty: (j['qty'] as num?)?.toInt() ?? 0,
      price: (j['price'] as num?)?.toDouble() ?? 0,
    );
  }
}

// ---------------------------------------------------------------------------
// STATE
// ---------------------------------------------------------------------------

class AppState extends ChangeNotifier {
  FirebaseFirestore get _db => FirebaseFirestore.instance;
  CollectionReference<Map<String, dynamic>> get _users => _db.collection('users');
  DocumentReference<Map<String, dynamic>> get _userDoc => _users.doc(userId);
  CollectionReference<Map<String, dynamic>> get _items => _userDoc.collection('items');
  CollectionReference<Map<String, dynamic>> get _logs => _userDoc.collection('logs');

  final List<Item> items = [];
  final List<LogEntry> logs = [];
  List<String> profiles = [];

  String userName = '';
  String storeName = '';
  int limit = 5;

  bool ready = false;
  String? error;

  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _itemsSub;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _logsSub;

  String get userId {
    var id = userName.trim().toLowerCase().replaceAll(RegExp(r'\s+'), '-');
    id = id.replaceAll('/', '');
    if (id.isEmpty) return 'guest';
    if (id == '.' || id == '..' || id.startsWith('__')) id = 'u-$id';
    return id;
  }

  bool get hasUser => userName.trim().isNotEmpty;

  Future<void> init() async {
    await _loadSettings();
    _db.settings = const Settings(persistenceEnabled: true);

    _users.snapshots().listen((snap) {
      profiles = snap.docs
          .map((d) => (d.data()['name'] as String?) ?? d.id)
          .toList()
        ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      notifyListeners();
    }, onError: _onError);

    if (hasUser) {
      _saveProfile();
      _startListening();
    } else {
      ready = true;
      notifyListeners();
    }
  }

  void _onError(Object e) {
    error = e.toString();
    ready = true;
    notifyListeners();
  }

  void _saveProfile() {
    if (!hasUser) return;
    _userDoc.set({
      'name': userName.trim(),
      'storeName': storeName.trim(),
      'lastUsed': Timestamp.now(),
    }, SetOptions(merge: true)).catchError((Object e) => _onError(e));
  }

  void _startListening() {
    _itemsSub?.cancel();
    _logsSub?.cancel();
    items.clear();
    logs.clear();
    ready = false;
    notifyListeners();

    _itemsSub = _items.snapshots().listen((snap) {
      items
        ..clear()
        ..addAll(snap.docs.map(Item.fromDoc))
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      ready = true;
      error = null;
      notifyListeners();
    }, onError: _onError);

    _logsSub = _logs.snapshots().listen((snap) {
      logs
        ..clear()
        ..addAll(snap.docs.map(LogEntry.fromDoc));
      notifyListeners();
    }, onError: _onError);
  }

  Future<void> _loadSettings() async {
    try {
      final p = await SharedPreferences.getInstance();
      userName = p.getString('userName') ?? '';
      storeName = p.getString('storeName') ?? '';
      limit = p.getInt('limit') ?? limit;
    } catch (_) {}
  }

  Future<void> _saveSettings() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString('userName', userName);
      await p.setString('storeName', storeName);
      await p.setInt('limit', limit);
    } catch (_) {}
  }

  void _settingsChanged() {
    notifyListeners();
    _saveSettings();
  }

  bool isLow(Item i) => i.qty <= limit;
  List<Item> get lowItems => items.where(isLow).toList();

  Item? findItem(String id) {
    for (final i in items) {
      if (i.id == id) return i;
    }
    return null;
  }

  List<LogEntry> logsFor(String itemId) =>
      logs.where((l) => l.itemId == itemId).toList()
        ..sort((a, b) => b.date.compareTo(a.date));

  String get initials {
    final parts = userName
        .trim()
        .split(RegExp(r'\s+'))
        .where((s) => s.isNotEmpty)
        .toList();
    if (parts.isEmpty) return '?';
    final first = parts[0][0];
    final second = parts.length > 1 ? parts[1][0] : '';
    return (first + second).toUpperCase();
  }

  void _commit(WriteBatch batch) {
    batch.commit().catchError((Object e) => _onError(e));
  }

  void setUser({required String name, required String store}) {
    userName = name.trim();
    storeName = store.trim().isEmpty ? '$userName\'s Store' : store.trim();
    _saveSettings();
    _saveProfile();
    _startListening();
  }

  void logoutToWelcome() {
    _itemsSub?.cancel();
    _logsSub?.cancel();
    userName = '';
    storeName = '';
    items.clear();
    logs.clear();
    _saveSettings();
    notifyListeners();
  }

  Future<void> deleteCurrentUser() async {
    if (!hasUser) return;

    final docRef = _userDoc;
    final itemsRef = _items;
    final logsRef = _logs;

    try {
      final itemSnap = await itemsRef.get();
      final logSnap = await logsRef.get();

      final batch = _db.batch();
      for (final doc in itemSnap.docs) {
        batch.delete(doc.reference);
      }
      for (final doc in logSnap.docs) {
        batch.delete(doc.reference);
      }
      batch.delete(docRef);

      await batch.commit();
    } catch (e) {
      _onError(e);
    } finally {
      logoutToWelcome();
    }
  }

  void addItem(String name, int qty, double price) {
    final now = DateTime.now();
    final ref = _items.doc();
    final batch = _db.batch();
    batch.set(ref, Item(id: ref.id, name: name, qty: qty, price: price, added: now).toMap());
    batch.set(
      _logs.doc(),
      LogEntry(
        date: now,
        itemId: ref.id,
        itemName: name,
        type: LogType.newItem,
        qty: qty,
        price: price,
      ).toMap(),
    );
    _commit(batch);

    if (qty <= limit) {
      showLowStockNotification(name, qty);
    }
  }

  void changeStock(Item item, int delta) {
    final now = DateTime.now();
    final newQty = item.qty + delta;

    final batch = _db.batch();
    batch.update(_items.doc(item.id), {
      'qty': FieldValue.increment(delta),
      'updated': Timestamp.fromDate(now),
    });
    batch.set(
      _logs.doc(),
      LogEntry(
        date: now,
        itemId: item.id,
        itemName: item.name,
        type: delta > 0 ? LogType.stockIn : LogType.stockOut,
        qty: delta.abs(),
        price: item.price,
      ).toMap(),
    );
    _commit(batch);

    if (newQty <= limit) {
      showLowStockNotification(item.name, newQty);
    }
  }

  void deleteItem(Item item) {
    final batch = _db.batch();
    batch.delete(_items.doc(item.id));
    batch.set(
      _logs.doc(),
      LogEntry(
        date: DateTime.now(),
        itemId: item.id,
        itemName: item.name,
        type: LogType.removed,
        qty: item.qty,
        price: item.price,
      ).toMap(),
    );
    _commit(batch);
  }

  void setStoreName(String v) {
    storeName = v;
    _saveProfile();
    _settingsChanged();
  }

  void setLimit(int v) {
    limit = math.max(0, v);
    _settingsChanged();
  }

  void loadSamples() {
    final batch = _db.batch();
    final now = DateTime.now();

    DateTime at(int daysAgo, int hour) {
      final d = now.subtract(Duration(days: daysAgo));
      return DateTime(d.year, d.month, d.day, hour, 30);
    }

    final names = <(String, int, double)>[
      ('Rice (1 kg)', 20, 55),
      ('Canned Sardines', 4, 25),
      ('Instant Noodles', 12, 14),
      ('Coffee Sachet', 3, 8),
      ('Softdrinks', 8, 20),
      ('Eggs', 2, 10),
    ];

    final ids = <String>[];
    for (final s in names) {
      final ref = _items.doc();
      ids.add(ref.id);
      batch.set(
        ref,
        Item(
          id: ref.id,
          name: s.$1,
          qty: s.$2,
          price: s.$3,
          added: at(7, 8),
        ).toMap(),
      );
    }

    void log(int i, LogType type, int qty, DateTime when) {
      batch.set(
        _logs.doc(),
        LogEntry(
          date: when,
          itemId: ids[i],
          itemName: names[i].$1,
          type: type,
          qty: qty,
          price: names[i].$3,
        ).toMap(),
      );
    }

    log(0, LogType.stockOut, 5, at(3, 9));
    log(5, LogType.stockOut, 12, at(2, 10));
    log(1, LogType.stockOut, 6, at(1, 14));
    log(2, LogType.stockIn, 24, at(1, 15));
    log(4, LogType.stockOut, 10, at(1, 17));
    log(3, LogType.stockOut, 15, at(0, 7));
    log(5, LogType.stockOut, 6, at(0, 8));

    _commit(batch);
  }
}

final AppState appState = AppState();

const List<(String, double)> quickItems = [
  ('Rice (1 kg)', 55),
  ('Canned Sardines', 25),
  ('Instant Noodles', 14),
  ('Coffee Sachet', 8),
  ('Softdrinks', 20),
  ('Eggs', 10),
  ('Sugar (1 kg)', 70),
  ('Cooking Oil', 15),
  ('Bread', 12),
  ('Soy Sauce', 15),
  ('Biscuits', 8),
  ('Laundry Soap', 10),
];

// ---------------------------------------------------------------------------
// MAIN APP
// ---------------------------------------------------------------------------

class TindaTrackApp extends StatelessWidget {
  const TindaTrackApp({super.key});

  static const Color seed = Color(0xFFB85042);

  @override
  Widget build(BuildContext context) {
    const bigText = TextStyle(fontSize: 18, fontWeight: FontWeight.bold);
    return MaterialApp(
      title: 'TindaTrack',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: seed),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            minimumSize: const Size(64, 56),
            textStyle: bigText,
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(64, 56),
            textStyle: bigText,
          ),
        ),
      ),
      home: ListenableBuilder(
        listenable: appState,
        builder: (context, _) {
          if (!appState.hasUser) {
            return const WelcomeScreen();
          }
          return const MainShell();
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// WELCOME SCREEN
// ---------------------------------------------------------------------------

class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key});

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen> {
  final _nameCtrl = TextEditingController();
  final _storeCtrl = TextEditingController();

  @override
  void dispose() {
    _nameCtrl.dispose();
    _storeCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _nameCtrl.text.trim();
    final store = _storeCtrl.text.trim();

    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter your name.')),
      );
      return;
    }

    appState.setUser(
      name: name,
      store: store.isEmpty ? '$name Store' : store,
    );
  }

  void _selectProfile(String profileName) {
    appState.setUser(
      name: profileName,
      store: '$profileName Store',
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const SizedBox(height: 32),
            Icon(Icons.storefront_rounded, size: 80, color: cs.primary),
            const SizedBox(height: 16),
            Text(
              'Welcome to TindaTrack',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              'Easy inventory tracking for your sari-sari store.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 16, color: cs.outline),
            ),
            const SizedBox(height: 32),
            Card(
              elevation: 0,
              color: cs.surfaceContainerHigh,
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Create New Profile',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _nameCtrl,
                      style: const TextStyle(fontSize: 18),
                      decoration: const InputDecoration(
                        labelText: 'Your Name',
                        hintText: 'e.g., Aling Marites',
                        prefixIcon: Icon(Icons.person_outline),
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _storeCtrl,
                      style: const TextStyle(fontSize: 18),
                      decoration: const InputDecoration(
                        labelText: 'Store Name',
                        hintText: 'e.g., Marites Sari-Sari Store',
                        prefixIcon: Icon(Icons.store_outlined),
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 20),
                    FilledButton.icon(
                      onPressed: _submit,
                      icon: const Icon(Icons.arrow_forward),
                      label: const Text('Get Started'),
                    ),
                  ],
                ),
              ),
            ),
            if (appState.profiles.isNotEmpty) ...[
              const SizedBox(height: 32),
              Text(
                'Or Select an Existing Profile',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 12),
              ...appState.profiles.map(
                (p) => Card(
                  child: ListTile(
                    leading: const CircleAvatar(child: Icon(Icons.person)),
                    title: Text(p, style: const TextStyle(fontSize: 18)),
                    subtitle: Text('$p Store'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _selectProfile(p),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// MAIN SHELL
// ---------------------------------------------------------------------------

class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _index = 0;

  void _goTo(int i) => setState(() => _index = i);

  @override
  Widget build(BuildContext context) {
    final pages = <Widget>[
      HomeScreen(onGoTo: _goTo),
      const InventoryScreen(),
      const ReportsScreen(),
      const SettingsScreen(),
    ];

    return Scaffold(
      body: IndexedStack(index: _index, children: pages),
      bottomNavigationBar: NavigationBar(
        height: 76,
        selectedIndex: _index,
        onDestinationSelected: _goTo,
        destinations: const [
          NavigationDestination(
              icon: Icon(Icons.home_outlined, size: 28),
              selectedIcon: Icon(Icons.home, size: 28),
              label: 'Home'),
          NavigationDestination(
              icon: Icon(Icons.inventory_2_outlined, size: 28),
              selectedIcon: Icon(Icons.inventory_2, size: 28),
              label: 'Inventory'),
          NavigationDestination(
              icon: Icon(Icons.bar_chart_outlined, size: 28),
              selectedIcon: Icon(Icons.bar_chart, size: 28),
              label: 'Reports'),
          NavigationDestination(
              icon: Icon(Icons.settings_outlined, size: 28),
              selectedIcon: Icon(Icons.settings, size: 28),
              label: 'Settings'),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// SHARED WIDGETS
// ---------------------------------------------------------------------------

void openDetail(BuildContext context, String id) {
  Navigator.push(
    context,
    MaterialPageRoute(builder: (_) => ItemDetailScreen(itemId: id)),
  );
}

void openAddItem(BuildContext context) {
  Navigator.push(
    context,
    MaterialPageRoute(builder: (_) => const AddItemScreen()),
  );
}

Widget loadingScreen(String title) => Scaffold(
      appBar: AppBar(title: Text(title)),
      body: const Center(child: CircularProgressIndicator()),
    );

class StockBadge extends StatelessWidget {
  const StockBadge({super.key, required this.text, required this.low});

  final String text;
  final bool low;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: low ? cs.errorContainer : cs.secondaryContainer,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontWeight: FontWeight.bold,
          fontSize: 15,
          color: low ? cs.onErrorContainer : cs.onSecondaryContainer,
        ),
      ),
    );
  }
}

class ItemTile extends StatelessWidget {
  const ItemTile({super.key, required this.item});

  final Item item;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      title: Text(item.name, style: const TextStyle(fontSize: 18)),
      subtitle: Text('${money(item.price)} each', style: const TextStyle(fontSize: 15)),
      trailing: StockBadge(text: '${item.qty} pcs', low: appState.isLow(item)),
      onTap: () => openDetail(context, item.id),
    );
  }
}

class LogTile extends StatelessWidget {
  const LogTile({super.key, required this.entry});

  final LogEntry entry;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final (icon, title) = switch (entry.type) {
      LogType.newItem => (
          Icons.add_box_outlined,
          'New item: ${entry.itemName} (${entry.qty} pcs)'
        ),
      LogType.stockIn => (
          Icons.south_west,
          'Stock in: ${entry.qty} × ${entry.itemName}'
        ),
      LogType.stockOut => (
          Icons.shopping_cart_outlined,
          'Sold: ${entry.qty} × ${entry.itemName}'
        ),
      LogType.removed => (
          Icons.delete_outline,
          'Removed: ${entry.itemName}'
        ),
    };

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 12),
      leading: Icon(icon, color: cs.primary),
      title: Text(title, style: const TextStyle(fontSize: 16)),
      subtitle: Text(fmtDateTime(entry.date)),
      trailing: entry.type == LogType.stockOut
          ? Text(money(entry.qty * entry.price),
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold))
          : null,
    );
  }
}

class BigStepButton extends StatelessWidget {
  const BigStepButton({super.key, required this.icon, required this.onPressed});

  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton.filledTonal(
      iconSize: 36,
      style: IconButton.styleFrom(minimumSize: const Size(68, 68)),
      onPressed: onPressed,
      icon: Icon(icon),
    );
  }
}

class StatCard extends StatelessWidget {
  const StatCard({
    super.key,
    required this.value,
    required this.label,
    required this.color,
    required this.textColor,
  });

  final String value;
  final String label;
  final Color color;
  final Color textColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(value,
                style: TextStyle(
                    fontSize: 32, fontWeight: FontWeight.bold, color: textColor)),
          ),
          Text(label, style: TextStyle(fontSize: 16, color: textColor)),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 1. HOME DASHBOARD
// ---------------------------------------------------------------------------

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, required this.onGoTo});

  final void Function(int) onGoTo;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appState,
      builder: (context, _) {
        if (!appState.ready) return loadingScreen('Home Dashboard');

        final cs = Theme.of(context).colorScheme;
        final low = appState.lowItems;
        final name = appState.userName.trim();
        final now = DateTime.now();

        final soldToday = appState.logs
            .where((l) => l.type == LogType.stockOut && sameDay(l.date, now))
            .toList();
        final piecesToday = soldToday.fold<int>(0, (s, l) => s + l.qty);
        final salesToday =
            soldToday.fold<double>(0, (s, l) => s + l.qty * l.price);

        return Scaffold(
          appBar: AppBar(
            title: Row(
              children: [
                const Text('Home Dashboard'),
                const SizedBox(width: 8),
                Chip(
                  label: const Text('TindaTrack'),
                  visualDensity: VisualDensity.compact,
                  backgroundColor: cs.primaryContainer,
                ),
              ],
            ),
          ),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (appState.error != null)
                Card(
                  color: cs.errorContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      'Cannot reach the database: ${appState.error}',
                      style: TextStyle(color: cs.onErrorContainer),
                    ),
                  ),
                ),
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Hi, ${name.isEmpty ? 'there' : name}! 👋',
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                        Text('${appState.storeName} · ${fmtDate(now)}'),
                      ],
                    ),
                  ),
                  CircleAvatar(
                    radius: 24,
                    child: Text(appState.initials,
                        style: const TextStyle(fontSize: 18)),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: StatCard(
                      value: '${appState.items.length}',
                      label: 'Total items',
                      color: cs.primary,
                      textColor: cs.onPrimary,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: StatCard(
                      value: '${low.length}',
                      label: 'Low stock',
                      color: cs.inverseSurface,
                      textColor: cs.onInverseSurface,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Card(
                child: ListTile(
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  leading: Icon(Icons.shopping_cart_outlined,
                      size: 32, color: cs.primary),
                  title: Text('Sold today: $piecesToday pcs',
                      style: const TextStyle(fontSize: 18)),
                  subtitle: Text('Sales: ${money(salesToday)}',
                      style: const TextStyle(fontSize: 16)),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => onGoTo(2),
                ),
              ),
              const SizedBox(height: 12),
              if (appState.items.isEmpty)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                        const Text(
                          'No items yet for this user. Add your first item, '
                          'or load some sample items to try the app.',
                          style: TextStyle(fontSize: 16),
                        ),
                        const SizedBox(height: 12),
                        OutlinedButton(
                          onPressed: appState.loadSamples,
                          child: const Text('Load sample items'),
                        ),
                      ],
                    ),
                  ),
                )
              else
                Card(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                          child: Text('Needs restocking',
                              style: Theme.of(context).textTheme.titleLarge),
                        ),
                        if (low.isEmpty)
                          const Padding(
                            padding: EdgeInsets.all(16),
                            child: Text('All items are well stocked.',
                                style: TextStyle(fontSize: 16)),
                          )
                        else
                          ...low.take(5).map((i) => ItemTile(item: i)),
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () => openAddItem(context),
                icon: const Icon(Icons.add),
                label: const Text('Add New Item'),
              ),
              const SizedBox(height: 12),
              FilledButton.tonal(
                onPressed: () => onGoTo(1),
                child: const Text('View Inventory'),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// 2. INVENTORY SCREEN
// ---------------------------------------------------------------------------

enum StockFilter { all, low, ok }

class InventoryScreen extends StatefulWidget {
  const InventoryScreen({super.key});

  @override
  State<InventoryScreen> createState() => _InventoryScreenState();
}

class _InventoryScreenState extends State<InventoryScreen> {
  String _query = '';
  StockFilter _filter = StockFilter.all;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appState,
      builder: (context, _) {
        if (!appState.ready) return loadingScreen('Inventory');

        final list = appState.items.where((i) {
          final matches = i.name.toLowerCase().contains(_query.toLowerCase());
          final low = appState.isLow(i);
          final passes = switch (_filter) {
            StockFilter.all => true,
            StockFilter.low => low,
            StockFilter.ok => !low,
          };
          return matches && passes;
        }).toList();

        return Scaffold(
          appBar: AppBar(title: const Text('Inventory')),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () => openAddItem(context),
            icon: const Icon(Icons.add),
            label: const Text('Add Item',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          ),
          body: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: TextField(
                  style: const TextStyle(fontSize: 18),
                  onChanged: (v) => setState(() => _query = v),
                  decoration: InputDecoration(
                    hintText: 'Search items...',
                    prefixIcon: const Icon(Icons.search),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(30),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    _chip('All', StockFilter.all),
                    const SizedBox(width: 8),
                    _chip('Low', StockFilter.low),
                    const SizedBox(width: 8),
                    _chip('In stock', StockFilter.ok),
                  ],
                ),
              ),
              Expanded(
                child: list.isEmpty
                    ? const Center(
                        child: Text('No items found.',
                            style: TextStyle(fontSize: 18)))
                    : ListView.builder(
                        padding: const EdgeInsets.only(bottom: 100),
                        itemCount: list.length,
                        itemBuilder: (_, i) => ItemTile(item: list[i]),
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _chip(String label, StockFilter value) {
    return ChoiceChip(
      label: Text(label, style: const TextStyle(fontSize: 16)),
      selected: _filter == value,
      onSelected: (_) => setState(() => _filter = value),
    );
  }
}

// ---------------------------------------------------------------------------
// 3. REPORTS SCREEN
// ---------------------------------------------------------------------------

class ReportsScreen extends StatelessWidget {
  const ReportsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appState,
      builder: (context, _) {
        if (!appState.ready) return loadingScreen('Reports');

        final salesLogs =
            appState.logs.where((l) => l.type == LogType.stockOut).toList();

        final totalRevenue =
            salesLogs.fold<double>(0, (sum, l) => sum + (l.qty * l.price));
        final totalItemsSold =
            salesLogs.fold<int>(0, (sum, l) => sum + l.qty);

        return Scaffold(
          appBar: AppBar(title: const Text('Reports & Sales History')),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Total Revenue',
                                style: TextStyle(fontSize: 16)),
                            const SizedBox(height: 4),
                            Text(money(totalRevenue),
                                style: const TextStyle(
                                    fontSize: 24, fontWeight: FontWeight.bold)),
                          ],
                        ),
                      ),
                      Container(height: 40, width: 1, color: Colors.grey.shade300),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.only(left: 16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('Items Sold',
                                  style: TextStyle(fontSize: 16)),
                              const SizedBox(height: 4),
                              Text('$totalItemsSold pcs',
                                  style: const TextStyle(
                                      fontSize: 24, fontWeight: FontWeight.bold)),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                        child: Text('Recent Activity',
                            style: Theme.of(context).textTheme.titleLarge),
                      ),
                      if (appState.logs.isEmpty)
                        const Padding(
                          padding: EdgeInsets.all(16),
                          child: Text('No transaction logs recorded yet.',
                              style: TextStyle(fontSize: 16)),
                        )
                      else
                        ...appState.logs.reversed
                            .take(20)
                            .map((l) => LogTile(entry: l)),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// 4. SETTINGS SCREEN
// ---------------------------------------------------------------------------

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late TextEditingController _storeCtrl;
  late TextEditingController _limitCtrl;

  @override
  void initState() {
    super.initState();
    _storeCtrl = TextEditingController(text: appState.storeName);
    _limitCtrl = TextEditingController(text: '${appState.limit}');
  }

  @override
  void dispose() {
    _storeCtrl.dispose();
    _limitCtrl.dispose();
    super.dispose();
  }

  Future<void> _confirmDeleteUser() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Account?'),
        content: Text(
          'Are you sure you want to delete profile "${appState.userName}"? '
          'This will permanently erase all inventory items and activity logs for this user from Firestore.',
          style: const TextStyle(fontSize: 16),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel', style: TextStyle(fontSize: 18)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete Permanently'),
          ),
        ],
      ),
    );

    if (ok == true && mounted) {
      await appState.deleteCurrentUser();
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: ListTile(
              leading: CircleAvatar(
                child: Text(appState.initials),
              ),
              title: Text(appState.userName,
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.bold)),
              subtitle: Text(appState.storeName),
              trailing: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(40, 40),
                ),
                onPressed: () {
                  appState.logoutToWelcome();
                },
                icon: const Icon(Icons.swap_horiz),
                label: const Text('Change User'),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Store Info',
                      style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _storeCtrl,
                    style: const TextStyle(fontSize: 18),
                    decoration: const InputDecoration(
                      labelText: 'Store Name',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (v) => appState.setStoreName(v),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _limitCtrl,
                    keyboardType: TextInputType.number,
                    style: const TextStyle(fontSize: 18),
                    decoration: const InputDecoration(
                      labelText: 'Low Stock Alert Threshold (pcs)',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (v) {
                      final n = int.tryParse(v);
                      if (n != null) appState.setLimit(n);
                    },
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            color: cs.surfaceContainerHigh,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Database & Users',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  Text(
                    'All profiles and inventory are saved under Firestore. '
                    'Changing users switches the local view without deleting old data.',
                    style: TextStyle(color: cs.outline),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: cs.error,
              side: BorderSide(color: cs.error),
            ),
            onPressed: _confirmDeleteUser,
            icon: const Icon(Icons.delete_forever),
            label: const Text('Delete This User Account'),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// ITEM DETAIL SCREEN
// ---------------------------------------------------------------------------

class ItemDetailScreen extends StatefulWidget {
  const ItemDetailScreen({super.key, required this.itemId});

  final String itemId;

  @override
  State<ItemDetailScreen> createState() => _ItemDetailScreenState();
}

class _ItemDetailScreenState extends State<ItemDetailScreen> {
  int _amount = 1;

  void _apply(Item item, bool isSold) {
    if (isSold && _amount > item.qty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Only ${item.qty} left in stock.')),
      );
      return;
    }
    appState.changeStock(item, isSold ? -_amount : _amount);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(isSold
            ? 'Saved: sold $_amount × ${item.name}'
            : 'Saved: stock in $_amount × ${item.name}'),
      ),
    );
    setState(() => _amount = 1);
  }

  Future<void> _confirmDelete(Item item) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete item?'),
        content: Text('Remove "${item.name}" from your inventory?',
            style: const TextStyle(fontSize: 16)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel', style: TextStyle(fontSize: 18)),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok == true && mounted) {
      appState.deleteItem(item);
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appState,
      builder: (context, _) {
        final item = appState.findItem(widget.itemId);

        if (!appState.ready) return loadingScreen('Item Details');

        if (item == null) {
          return Scaffold(
            appBar: AppBar(title: const Text('Item Details')),
            body: const Center(
              child: Text(
                'This item was removed.',
                style: TextStyle(fontSize: 18),
              ),
            ),
          );
        }

        final cs = Theme.of(context).colorScheme;
        final history = appState.logsFor(item.id);

        return Scaffold(
          appBar: AppBar(
            title: Text(item.name),
            actions: [
              IconButton(
                icon: const Icon(Icons.delete_outline),
                tooltip: 'Delete Item',
                onPressed: () => _confirmDelete(item),
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('Current Stock:',
                              style: TextStyle(fontSize: 18)),
                          StockBadge(
                            text: '${item.qty} pcs',
                            low: appState.isLow(item),
                          ),
                        ],
                      ),
                      const Divider(height: 24),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('Price per piece:',
                              style: TextStyle(fontSize: 18)),
                          Text(
                            money(item.price),
                            style: const TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Icon(Icons.calendar_today_outlined,
                              size: 16, color: cs.outline),
                          const SizedBox(width: 6),
                          Text(
                            'Added: ${fmtDate(item.added)}',
                            style: TextStyle(color: cs.outline, fontSize: 14),
                          ),
                          const Spacer(),
                          Icon(Icons.history, size: 16, color: cs.outline),
                          const SizedBox(width: 6),
                          Text(
                            'Updated: ${fmtDate(item.updated)}',
                            style: TextStyle(color: cs.outline, fontSize: 14),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'Update Stock',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 16),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          BigStepButton(
                            icon: Icons.remove,
                            onPressed: () {
                              if (_amount > 1) {
                                setState(() => _amount--);
                              }
                            },
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 24),
                            child: Text(
                              '$_amount',
                              style: const TextStyle(
                                fontSize: 36,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          BigStepButton(
                            icon: Icons.add,
                            onPressed: () => setState(() => _amount++),
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),
                      Row(
                        children: [
                          Expanded(
                            child: FilledButton.icon(
                              style: FilledButton.styleFrom(
                                backgroundColor: cs.error,
                                foregroundColor: cs.onError,
                              ),
                              onPressed: () => _apply(item, true),
                              icon: const Icon(Icons.shopping_cart_outlined),
                              label: const Text('Sold'),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: FilledButton.icon(
                              onPressed: () => _apply(item, false),
                              icon: const Icon(Icons.add_box_outlined),
                              label: const Text('Stock In'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                        child: Text(
                          'Item Activity',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ),
                      if (history.isEmpty)
                        const Padding(
                          padding: EdgeInsets.all(16),
                          child: Text(
                            'No activity recorded yet.',
                            style: TextStyle(fontSize: 16),
                          ),
                        )
                      else
                        ...history.map((e) => LogTile(entry: e)),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// ADD ITEM SCREEN
// ---------------------------------------------------------------------------

class AddItemScreen extends StatefulWidget {
  const AddItemScreen({super.key});

  @override
  State<AddItemScreen> createState() => _AddItemScreenState();
}

class _AddItemScreenState extends State<AddItemScreen> {
  final _nameCtrl = TextEditingController();
  final _qtyCtrl = TextEditingController(text: '10');
  final _priceCtrl = TextEditingController();

  @override
  void dispose() {
    _nameCtrl.dispose();
    _qtyCtrl.dispose();
    _priceCtrl.dispose();
    super.dispose();
  }

  void _save() {
    final name = _nameCtrl.text.trim();
    final qty = int.tryParse(_qtyCtrl.text.trim()) ?? 0;
    final price = double.tryParse(_priceCtrl.text.trim()) ?? 0;

    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter an item name.')),
      );
      return;
    }

    appState.addItem(name, qty, price);
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Add New Item')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _nameCtrl,
            style: const TextStyle(fontSize: 18),
            decoration: const InputDecoration(
              labelText: 'Item Name',
              hintText: 'e.g., Rice 1kg, Instant Noodles',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _qtyCtrl,
                  keyboardType: TextInputType.number,
                  style: const TextStyle(fontSize: 18),
                  decoration: const InputDecoration(
                    labelText: 'Initial Quantity',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _priceCtrl,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  style: const TextStyle(fontSize: 18),
                  decoration: const InputDecoration(
                    labelText: 'Price (₱)',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          Text(
            'Or select a common item:',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: quickItems.map((qi) {
              return ActionChip(
                label: Text('${qi.$1} (${money(qi.$2)})'),
                onPressed: () {
                  _nameCtrl.text = qi.$1;
                  _priceCtrl.text = qi.$2.toStringAsFixed(0);
                },
              );
            }).toList(),
          ),
          const SizedBox(height: 32),
          FilledButton(
            onPressed: _save,
            child: const Text('Save Item'),
          ),
        ],
      ),
    );
  }
}