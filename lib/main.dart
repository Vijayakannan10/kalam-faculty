import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'firebase_config.dart';
import 'rooms.dart';

// ---------------- Beacon rules (from the home test with ESP32) ----------------
// Near the beacon: about -45 dBm. Other side / another room: -60 to -80 dBm.
const int enterRssi = -65;          // stronger than this = inside the room
const int leaveRssi = -80;          // weaker than this = left the room
const int switchMargin = 6;         // another room must be this much stronger to switch
const Duration lostAfter = Duration(seconds: 15); // no signal for this long = not hearing that room now
// Near the cabin beacon = inside (door Open). Away from it = outside (door Closed).
// The short times only smooth out Bluetooth signal drops; they do not try to predict anything.
const Duration enterHold = Duration(seconds: 3);
const Duration leaveHold = Duration(seconds: 15);
const Duration heartbeat = Duration(minutes: 5);  // keep "updated" fresh while in a room
const String facultyCollection = 'faculty';

// Two apps are built from this code:
//   lib/main_faculty.dart -> "Kalam Faculty" (runs all day, reports the cabin door)
//   lib/main_student.dart -> "Kalam Student" (shows who is in their cabin)
enum AppMode { faculty, student }
AppMode appMode = AppMode.faculty;

Future<void> main() => runKalam(AppMode.faculty);

Future<void> runKalam(AppMode mode) async {
  appMode = mode;
  WidgetsFlutterBinding.ensureInitialized();
  String? initError;
  if (!firebaseConfigured) {
    initError = 'Firebase details are missing.\nFill the 4 values in lib/firebase_config.dart and build again.';
  } else {
    try {
      await Firebase.initializeApp(options: firebaseOptions);
    } catch (e) {
      initError = 'Could not connect to Firebase.\n$e';
    }
  }
  // Background mode: a small "Kalam Finder is running" notification keeps the app alive
  // so the cabin door keeps updating while the phone is locked or in a pocket.
  if (mode == AppMode.faculty) FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: 'kalam_finder',
      channelName: 'Kalam Finder',
      channelDescription: 'Keeps your cabin door status updated.',
      channelImportance: NotificationChannelImportance.LOW,
      priority: NotificationPriority.LOW,
    ),
    iosNotificationOptions: const IOSNotificationOptions(showNotification: false),
    foregroundTaskOptions: ForegroundTaskOptions(
      eventAction: ForegroundTaskEventAction.nothing(),
      allowWakeLock: true,
    ),
  );
  runApp(KalamApp(initError: initError));
}

class KalamApp extends StatelessWidget {
  final String? initError;
  const KalamApp({super.key, this.initError});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: appMode == AppMode.student ? 'Kalam Student' : 'Kalam Faculty',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: const Color(0xFF2B4FB8), useMaterial3: true),
      darkTheme: ThemeData(colorSchemeSeed: const Color(0xFF2B4FB8), useMaterial3: true, brightness: Brightness.dark),
      home: initError != null
          ? MessageScreen(message: initError!)
          : (appMode == AppMode.student ? const StudentHome() : const StartScreen()),
    );
  }
}

class MessageScreen extends StatelessWidget {
  final String message;
  const MessageScreen({super.key, required this.message});
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Kalam Faculty')),
        body: Padding(padding: const EdgeInsets.all(24), child: Text(message, style: const TextStyle(fontSize: 16))),
      );
}

// ---------------- Start: remember who this phone belongs to ----------------
class StartScreen extends StatefulWidget {
  const StartScreen({super.key});
  @override
  State<StartScreen> createState() => _StartScreenState();
}

class _StartScreenState extends State<StartScreen> {
  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    final prefs = await SharedPreferences.getInstance();
    final id = prefs.getString('facultyId');
    // A faculty is registered on this phone: keep their cabin scan running whatever screen is open.
    if (id != null) Presence.instance.start(id);
    if (!mounted) return;
    final Widget next = id != null ? HomeScreen(facultyId: id) : const PickFacultyScreen();
    Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => next));
  }

  @override
  Widget build(BuildContext context) => const Scaffold(body: Center(child: CircularProgressIndicator()));
}

// ---------------- Role: student or faculty ----------------
class RoleScreen extends StatelessWidget {
  const RoleScreen({super.key});

  Future<void> _pick(BuildContext context, String role) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('role', role);
    if (!context.mounted) return;
    final id = prefs.getString('facultyId');
    Navigator.of(context).pushReplacement(MaterialPageRoute(
      builder: (_) => role == 'student'
          ? const StudentScreen()
          : (id != null ? HomeScreen(facultyId: id) : const PickFacultyScreen()),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget option(IconData icon, String title, String sub, String role) => Card(
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => _pick(context, role),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Row(children: [
                Icon(icon, size: 40, color: scheme.primary),
                const SizedBox(width: 16),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  Text(sub, style: TextStyle(color: scheme.onSurfaceVariant)),
                ])),
              ]),
            ),
          ),
        );
    return Scaffold(
      appBar: AppBar(title: const Text('Kalam Finder')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        const Text('8th Block · Abdul Kalam Block', style: TextStyle(fontSize: 13)),
        const SizedBox(height: 12),
        option(Icons.school, "I'm a student", 'See which faculty are in their cabin right now.', 'student'),
        const SizedBox(height: 8),
        option(Icons.badge, "I'm faculty", 'Keep this app open. Your cabin door shows Open when you are inside.', 'faculty'),
      ]),
    );
  }
}

// ---------------- Student view: who is in their cabin ----------------
class StudentScreen extends StatefulWidget {
  final bool fromFaculty;
  final void Function(String facultyId)? onShowIn3D;
  const StudentScreen({super.key, this.fromFaculty = false, this.onShowIn3D});
  @override
  State<StudentScreen> createState() => _StudentScreenState();
}

class _StudentScreenState extends State<StudentScreen> {
  final _search = TextEditingController();
  Timer? _clock;

  @override
  void initState() {
    super.initState();
    _clock = Timer.periodic(const Duration(seconds: 30), (_) => setState(() {})); // refresh "updated … ago"
  }

  @override
  void dispose() {
    _clock?.cancel();
    _search.dispose();
    super.dispose();
  }

  String _ago(int? ms) {
    if (ms == null) return 'never updated';
    final m = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(ms)).inMinutes;
    if (m < 1) return 'updated just now';
    if (m < 60) return 'updated $m min ago';
    if (m < 1440) return 'updated ${m ~/ 60} hr ago';
    return 'updated ${m ~/ 1440} days ago';
  }

  Future<void> _switchRole() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('role');
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(MaterialPageRoute(builder: (_) => const RoleScreen()), (_) => false);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Find faculty'),
        actions: [
          if (!widget.fromFaculty && appMode != AppMode.student)
            IconButton(onPressed: _switchRole, icon: const Icon(Icons.swap_horiz), tooltip: 'Switch to faculty'),
        ],
      ),
      body: Column(children: [
        ListenableBuilder(
          listenable: Presence.instance,
          builder: (context, _) {
            final pr = Presence.instance;
            if (!pr.running) return const SizedBox.shrink();
            final name = (pr.me?['name'] ?? 'faculty').toString();
            return Container(
              width: double.infinity,
              color: scheme.secondaryContainer,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Text('This phone is also reporting $name\'s cabin door, even while you are on this screen.',
                  style: TextStyle(color: scheme.onSecondaryContainer)),
            );
          },
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: TextField(
            controller: _search,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search faculty name', border: OutlineInputBorder()),
          ),
        ),
        Expanded(
          child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: FirebaseFirestore.instance.collection(facultyCollection).orderBy('name').snapshots(),
            builder: (context, snap) {
              if (snap.hasError) return Center(child: Text('Could not load faculty.\n${snap.error}', textAlign: TextAlign.center));
              if (!snap.hasData) return const Center(child: CircularProgressIndicator());
              final q = _search.text.trim().toLowerCase();
              final docs = snap.data!.docs.where((d) => (d.data()['name'] ?? '').toString().toLowerCase().contains(q)).toList();
              if (docs.isEmpty) return const Center(child: Text('No faculty found.'));
              final inCount = snap.data!.docs.where((d) => d.data()['cabinOpen'] == true).length;
              return ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
                Text('$inCount of ${snap.data!.docs.length} faculty in their cabin now',
                    style: TextStyle(color: scheme.onSurfaceVariant)),
                const SizedBox(height: 8),
                for (final d in docs) _card(d.id, d.data(), scheme),
              ]);
            },
          ),
        ),
      ]),
    );
  }

  Widget _card(String id, Map<String, dynamic> f, ColorScheme scheme) {
    final open = f['cabinOpen'] == true;
    final gender = f['gender'] == 'F' ? 'L' : 'G';
    final cabin = 'Floor ${f['cabinFloor']} · Cabin $gender${f['cabinNo']}';
    final color = open ? Colors.green.shade600 : Colors.red.shade600;
    final ms = (f['updatedAt'] as num?)?.toInt();
    final since = _ago(ms).replaceFirst('updated ', '');
    return Card(
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: BorderSide(color: color, width: 2)),
      child: InkWell(
        onTap: widget.onShowIn3D == null ? null : () => widget.onShowIn3D!(id),
        child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(children: [
          Icon(open ? Icons.meeting_room : Icons.door_front_door, color: color, size: 44),
          const SizedBox(width: 14),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text((f['name'] ?? 'Faculty').toString(), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text(open ? 'Inside the cabin · Door OPEN' : 'Went out · Door CLOSED',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: color)),
            const SizedBox(height: 2),
            Text(open ? 'Go to $cabin' : 'Cabin: $cabin', style: TextStyle(color: scheme.onSurfaceVariant)),
            if (ms != null)
              Text(open ? 'Came in $since' : 'Left $since', style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
          ])),
          if (widget.onShowIn3D != null) Icon(Icons.view_in_ar, color: scheme.onSurfaceVariant),
        ]),
      ),
      ),
    );
  }
}

// ---------------- Kalam Student: List + 3D Block ----------------
class StudentHome extends StatefulWidget {
  const StudentHome({super.key});
  @override
  State<StudentHome> createState() => _StudentHomeState();
}

class _StudentHomeState extends State<StudentHome> {
  int _tab = 0;
  final _block = GlobalKey<_Block3DScreenState>();

  void _showIn3D(String id) {
    setState(() => _tab = 1);
    _block.currentState?.focusFaculty(id);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _tab, children: [
        StudentScreen(onShowIn3D: _showIn3D),
        Block3DScreen(key: _block),
      ]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.list_alt), label: 'Faculty list'),
          NavigationDestination(icon: Icon(Icons.view_in_ar), label: '3D Block'),
        ],
      ),
    );
  }
}

// The 3D Abdul Kalam Block (assets/block3d.html), fed with live faculty data from Firebase.
class Block3DScreen extends StatefulWidget {
  const Block3DScreen({super.key});
  @override
  State<Block3DScreen> createState() => _Block3DScreenState();
}

class _Block3DScreenState extends State<Block3DScreen> {
  late final WebViewController _web;
  StreamSubscription? _sub;
  bool _pageReady = false;
  String? _lastJson;
  String? _pendingFocus;

  @override
  void initState() {
    super.initState();
    _web = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(onPageFinished: (_) {
        _pageReady = true;
        _send();
        final f = _pendingFocus;
        if (f != null) focusFaculty(f);
      }))
      ..loadFlutterAsset('assets/block3d.html');
    _sub = FirebaseFirestore.instance.collection(facultyCollection).snapshots().listen((snap) {
      final list = snap.docs.map((d) {
        final f = d.data();
        return {
          'id': d.id,
          'name': (f['name'] ?? 'Faculty').toString(),
          'gender': (f['gender'] ?? 'M').toString(),
          'cabinFloor': (f['cabinFloor'] as num?)?.toInt(),
          'cabinNo': (f['cabinNo'] as num?)?.toInt(),
          'cabinOpen': f['cabinOpen'] == true,
          'updatedAt': (f['updatedAt'] as num?)?.toInt(),
        };
      }).toList();
      _lastJson = jsonEncode(list);
      _send();
    });
  }

  void _send() {
    final j = _lastJson;
    if (!_pageReady || j == null) return;
    _web.runJavaScript('window.setFaculty($j)').catchError((_) {});
  }

  void focusFaculty(String id) {
    if (!_pageReady || _lastJson == null) {
      _pendingFocus = id;
      return;
    }
    _pendingFocus = null;
    _web.runJavaScript('window.focusFaculty(${jsonEncode(id)})').catchError((_) {});
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Abdul Kalam Block · 3D')),
      body: WebViewWidget(controller: _web),
    );
  }
}

class PickFacultyScreen extends StatelessWidget {
  const PickFacultyScreen({super.key});

  Future<void> _choose(BuildContext context, String id) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('facultyId', id);
    await prefs.setString('role', 'faculty');
    if (!context.mounted) return;
    Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => HomeScreen(facultyId: id)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Who are you?')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          final id = await showDialog<String>(context: context, builder: (_) => const AddFacultyDialog());
          if (id != null && context.mounted) _choose(context, id);
        },
        icon: const Icon(Icons.person_add),
        label: const Text('Add me'),
      ),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance.collection(facultyCollection).orderBy('name').snapshots(),
        builder: (context, snap) {
          if (snap.hasError) return MessageScreen(message: 'Could not load faculty list.\n${snap.error}');
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final docs = snap.data!.docs;
          if (docs.isEmpty) {
            return const Center(child: Padding(
              padding: EdgeInsets.all(24),
              child: Text('No faculty added yet.\nTap "Add me" to add yourself.', textAlign: TextAlign.center),
            ));
          }
          return ListView(
            padding: const EdgeInsets.only(bottom: 96),
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text('Pick your name. This phone will then update your cabin door automatically. Long-press a name to remove it.'),
              ),
              for (final d in docs)
                ListTile(
                  leading: CircleAvatar(child: Text(_initials(d.data()['name'] ?? '?'))),
                  title: Text(d.data()['name'] ?? 'Faculty'),
                  subtitle: Text('Cabin: Floor ${d.data()['cabinFloor']}, ${d.data()['gender'] == 'F' ? 'L' : 'G'}${d.data()['cabinNo']}'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _choose(context, d.id),
                  onLongPress: () async {
                    final yes = await showDialog<bool>(context: context, builder: (c) => AlertDialog(
                      title: Text('Remove ${d.data()['name'] ?? 'this faculty'}?'),
                      content: const Text('This removes the entry for everyone. It cannot be undone.'),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
                        FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Remove')),
                      ],
                    ));
                    if (yes == true) {
                      try { await d.reference.delete(); } catch (_) {}
                    }
                  },
                ),
            ],
          );
        },
      ),
    );
  }
}

String _initials(String name) {
  final parts = name.replaceAll(RegExp(r'^(Dr|Mr|Mrs|Ms|Prof)\.?\s*', caseSensitive: false), '').split(RegExp(r'[\s.]+')).where((w) => w.isNotEmpty).toList();
  if (parts.isEmpty) return '?';
  return parts.length == 1 ? parts.first[0].toUpperCase() : (parts[parts.length - 2][0] + parts.last[0]).toUpperCase();
}

class AddFacultyDialog extends StatefulWidget {
  const AddFacultyDialog({super.key});
  @override
  State<AddFacultyDialog> createState() => _AddFacultyDialogState();
}

class _AddFacultyDialogState extends State<AddFacultyDialog> {
  final _name = TextEditingController();
  String _gender = 'M';
  int _floor = 4;
  int _cabin = 1;
  bool _saving = false;
  String? _error;

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Enter your name.');
      return;
    }
    setState(() { _saving = true; _error = null; });
    try {
      final ref = await FirebaseFirestore.instance.collection(facultyCollection).add({
        'name': name, 'gender': _gender, 'cabinFloor': _floor, 'cabinNo': _cabin,
        'status': 'away', 'floor': _floor, 'idx': cabinIdx(_gender, _cabin),
        'cabinOpen': false, 'note': '', 'updatedAt': DateTime.now().millisecondsSinceEpoch, 'source': 'app',
      });
      if (mounted) Navigator.of(context).pop(ref.id);
    } catch (e) {
      setState(() { _saving = false; _error = 'Could not save. Check internet and try again.'; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add me'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          TextField(controller: _name, decoration: const InputDecoration(labelText: 'Name, e.g. Dr. K. Ramesh')),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            value: _gender,
            decoration: const InputDecoration(labelText: 'Cabin side'),
            items: const [
              DropdownMenuItem(value: 'M', child: Text('Gents cabins (G1–G4)')),
              DropdownMenuItem(value: 'F', child: Text('Ladies cabins (L1–L4)')),
            ],
            onChanged: (v) => setState(() => _gender = v ?? 'M'),
          ),
          DropdownButtonFormField<int>(
            value: _floor,
            decoration: const InputDecoration(labelText: 'Cabin floor'),
            items: [for (final f in [3, 4, 5, 6]) DropdownMenuItem(value: f, child: Text('Floor $f'))],
            onChanged: (v) => setState(() => _floor = v ?? 4),
          ),
          DropdownButtonFormField<int>(
            value: _cabin,
            decoration: const InputDecoration(labelText: 'Cabin number'),
            items: [for (final c in [1, 2, 3, 4]) DropdownMenuItem(value: c, child: Text('${_gender == 'F' ? 'L' : 'G'}$c'))],
            onChanged: (v) => setState(() => _cabin = v ?? 1),
          ),
          if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
        ]),
      ),
      actions: [
        TextButton(onPressed: _saving ? null : () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(onPressed: _saving ? null : _save, child: Text(_saving ? 'Saving…' : 'Add')),
      ],
    );
  }
}

// ---------------- Home: scan beacons, update room ----------------
class Seen {
  double rssi;
  DateTime last;
  Seen(this.rssi, this.last);
}

// The faculty scan runs here, outside any screen, so it keeps going on every screen
// (student view, lock screen, other apps) for as long as a faculty is registered on this phone.
class Presence extends ChangeNotifier with WidgetsBindingObserver {
  Presence._();
  static final Presence instance = Presence._();

  String? facultyId;
  final Map<String, Seen> seen = {};
  final Map<String, DateTime> allDevices = {}; // Kalam beacons the scan returned (for the phone check)
  Map<Permission, PermissionStatus> perms = {};
  bool locationServiceOn = true;
  bool bgRunning = false;
  DateTime? scanStartedAt;
  DateTime? _lastAnyResult;
  Room? _candidate;           // a cabin heard strongly but not confirmed yet
  DateTime? _candidateSince;
  DateTime? _lastInRoom;      // last time the current cabin was clearly heard
  Room? room;                 // cabin the phone is in now (null = away)
  Map<String, dynamic>? me;   // this faculty's record in Firebase
  String? problem;
  DateTime? _lastWrite;
  StreamSubscription? _scanSub, _adapterSub, _meSub;
  Timer? _tick;

  bool get running => facultyId != null;

  DocumentReference<Map<String, dynamic>> get _doc =>
      FirebaseFirestore.instance.collection(facultyCollection).doc(facultyId);

  Future<void> start(String id) async {
    if (facultyId == id) return;
    if (facultyId != null) await stop();
    facultyId = id;
    WidgetsBinding.instance.addObserver(this);
    _meSub = _doc.snapshots().listen((snap) {
      final oldFloor = me?['cabinFloor'];
      me = snap.data();
      notifyListeners();
      if (me?['cabinFloor'] != oldFloor && scanStartedAt != null) {
        Future.delayed(const Duration(seconds: 9), () {
          if (facultyId == id) startScan(force: true);
        });
      }
    });
    _tick = Timer.periodic(const Duration(seconds: 2), (_) => _evaluate());
    await checkPermissions();
    await _startBackground();
    _adapterSub = FlutterBluePlus.adapterState.listen((state) async {
      if (state == BluetoothAdapterState.on) {
        problem = null;
        notifyListeners();
        await startScan();
      } else {
        problem = 'Turn on Bluetooth to detect your cabin.';
        notifyListeners();
      }
    });
    try { await FlutterBluePlus.turnOn(); } catch (_) {}
  }

  Future<void> stop() async {
    if (facultyId != null) {
      // signing out of this phone: show the door as closed
      try {
        _doc.update({'status': 'away', 'cabinOpen': false, 'updatedAt': DateTime.now().millisecondsSinceEpoch}).catchError((_) {});
      } catch (_) {}
    }
    WidgetsBinding.instance.removeObserver(this);
    _tick?.cancel();
    _tick = null;
    await _scanSub?.cancel();
    await _adapterSub?.cancel();
    await _meSub?.cancel();
    _scanSub = null;
    _adapterSub = null;
    _meSub = null;
    try { await FlutterBluePlus.stopScan(); } catch (_) {}
    try { await FlutterForegroundTask.stopService(); } catch (_) {}
    facultyId = null;
    me = null;
    room = null;
    _candidate = null;
    _candidateSince = null;
    _lastInRoom = null;
    seen.clear();
    allDevices.clear();
    scanStartedAt = null;
    _lastAnyResult = null;
    bgRunning = false;
    problem = null;
    notifyListeners();
  }

  Future<void> checkPermissions() async {
    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.location,
    ].request();
    bool service = true;
    try { service = await Permission.location.serviceStatus.isEnabled; } catch (_) {}
    perms = statuses;
    locationServiceOn = service;
    notifyListeners();
  }

  Future<void> _startBackground() async {
    try {
      final np = await FlutterForegroundTask.checkNotificationPermission();
      if (np != NotificationPermission.granted) {
        await FlutterForegroundTask.requestNotificationPermission();
      }
      if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
        await FlutterForegroundTask.requestIgnoreBatteryOptimization();
      }
      if (!await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.startService(
          serviceId: 701,
          notificationTitle: 'Kalam Finder is running',
          notificationText: 'Your cabin door updates automatically. Do not swipe the app away.',
        );
      }
      bgRunning = await FlutterForegroundTask.isRunningService;
    } catch (_) {
      bgRunning = false;
    }
    notifyListeners();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Android often stops the scan when the screen turns off or the app goes to the background.
    if (state == AppLifecycleState.resumed && running) startScan(force: true);
  }

  Future<void> startScan({bool force = false}) async {
    if (!running) return;
    final started = scanStartedAt;
    // Android blocks apps that start scans too often (5 per 30 s), so never restart faster than every 8 s.
    if (started != null && DateTime.now().difference(started) < const Duration(seconds: 8)) return;
    if (!force && started != null && FlutterBluePlus.isScanningNow) return;
    await _scanSub?.cancel();
    _scanSub = FlutterBluePlus.onScanResults.listen((results) {
      final now = DateTime.now();
      if (results.isNotEmpty) _lastAnyResult = now;
      for (final r in results) {
        allDevices[r.device.remoteId.str] = now;
        String name = r.advertisementData.advName;
        if (name.isEmpty) name = r.device.platformName;
        if (name.isEmpty) name = r.device.advName;
        if (!name.toUpperCase().startsWith('KALAM-')) continue;
        final s = seen[name];
        if (s == null) {
          seen[name] = Seen(r.rssi.toDouble(), now);
        } else {
          s.rssi = s.rssi * 0.7 + r.rssi * 0.3; // smooth the jumpy signal
          s.last = now;
        }
      }
    }, onError: (e) {
      problem = 'Bluetooth scan error: $e';
      notifyListeners();
    });
    try {
      if (FlutterBluePlus.isScanningNow) await FlutterBluePlus.stopScan();
      scanStartedAt = DateTime.now();
      await FlutterBluePlus.startScan(
        withNames: _scanNames(), // a filtered scan keeps working when the screen turns off
        continuousUpdates: true,
        androidScanMode: AndroidScanMode.lowLatency,
        androidUsesFineLocation: true,
      );
    } catch (e) {
      problem = 'Could not start Bluetooth scan: $e';
      notifyListeners();
    }
  }

  void _evaluate() {
    if (!running) return;
    final now = DateTime.now();

    // Watchdog: if the scan has gone silent, restart it (Android stops scans without telling the app).
    final scanAlive = _lastAnyResult != null && now.difference(_lastAnyResult!) < const Duration(seconds: 12);
    final started = scanStartedAt;
    if (FlutterBluePlus.adapterStateNow == BluetoothAdapterState.on && started != null) {
      if (!scanAlive && now.difference(started) > const Duration(seconds: 20)) startScan(force: true);
      if (now.difference(started) > const Duration(minutes: 10)) startScan(force: true); // regular refresh
    }
    seen.removeWhere((_, s) => now.difference(s.last) > const Duration(minutes: 2));

    // strongest cabin the phone hears right now
    MapEntry<String, Seen>? best;
    for (final e in seen.entries) {
      if (now.difference(e.value.last) > lostAfter) continue;
      if (parseBeacon(e.key) == null) continue;
      if (best == null || e.value.rssi > best.value.rssi) best = e;
    }

    // is the current cabin still clearly heard?
    Seen? cur;
    bool curOk = false;
    if (room != null) {
      cur = seen[room!.beaconName];
      curOk = cur != null && now.difference(cur.last) <= lostAfter && cur.rssi >= leaveRssi;
      if (curOk) _lastInRoom = now;
    }

    // a different cabin heard strongly becomes a candidate; it must stay that way for a few seconds
    Room? cand;
    if (best != null && best.value.rssi >= enterRssi && best.key != room?.beaconName) {
      final muchStronger = !curOk || best.value.rssi > cur!.rssi + switchMargin;
      if (muchStronger) cand = parseBeacon(best.key);
    }
    if (cand == null) {
      _candidate = null;
      _candidateSince = null;
    } else if (_candidate?.beaconName != cand.beaconName) {
      _candidate = cand;
      _candidateSince = now;
    }

    if (_candidate != null && now.difference(_candidateSince!) >= enterHold) {
      room = _candidate;
      _lastInRoom = now;
      _candidate = null;
      _candidateSince = null;
    } else if (room != null && _lastInRoom != null && now.difference(_lastInRoom!) >= leaveHold) {
      room = null; // away: left the cabin
    }

    _sync(now);
    notifyListeners();
  }

  // Every 2 seconds: make sure Firebase shows what the phone sees right now. If not, fix it.
  void _sync(DateTime now) {
    final m = me;
    if (m == null) return;
    final r = room;
    final wantOpen = r != null && isOwnCabin(r);
    final wantStatus = r == null ? 'away' : (wantOpen ? 'cabin' : 'class');
    final same = m['cabinOpen'] == wantOpen && m['status'] == wantStatus &&
        (r == null || ((m['floor'] as num?)?.toInt() == r.floor && (m['idx'] as num?)?.toInt() == r.idx));
    if (!same) {
      _push(r);
    } else if (r != null && (_lastWrite == null || now.difference(_lastWrite!) > heartbeat)) {
      _push(r, heartbeatOnly: true);
    }
  }

  // Listen only for the cabins on your own floor (8 names). Android keeps a filtered scan running
  // when the screen is off, and a short list fits in every phone's Bluetooth chip.
  List<String> _scanNames() {
    final f = (me?['cabinFloor'] as num?)?.toInt();
    if (f == null) return [];
    return [for (final side in ['G', 'L']) for (var n = 1; n <= 4; n++) 'KALAM-$f$side$n'];
  }

  String myCabinLabel() {
    final m = me;
    if (m == null) return 'not set';
    return 'Floor ${m['cabinFloor']}, ${m['gender'] == 'F' ? 'L' : 'G'}${m['cabinNo']}';
  }

  Future<void> makeMyCabin(Room r) async {
    final gents = r.idx <= 4;
    try {
      await _doc.update({
        'cabinFloor': r.floor,
        'gender': gents ? 'M' : 'F',
        'cabinNo': gents ? r.idx : r.idx - 4,
        'status': 'cabin', 'floor': r.floor, 'idx': r.idx,
        'cabinOpen': true,
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
      });
    } catch (_) {}
  }

  bool isOwnCabin(Room r) {
    final m = me;
    if (m == null) return false;
    return r.floor == (m['cabinFloor'] as num?)?.toInt() &&
        r.idx == cabinIdx(m['gender'] ?? 'M', (m['cabinNo'] as num?)?.toInt() ?? 0);
  }

  void _push(Room? r, {bool heartbeatOnly = false}) {
    final now = DateTime.now();
    if (_lastWrite != null && now.difference(_lastWrite!) < const Duration(seconds: 1)) return;
    final data = <String, dynamic>{'updatedAt': now.millisecondsSinceEpoch, 'source': 'beacon'};
    if (!heartbeatOnly) {
      if (r != null) {
        final own = isOwnCabin(r);
        data.addAll({'status': own ? 'cabin' : 'class', 'floor': r.floor, 'idx': r.idx});
        data['cabinOpen'] = own; // door is open only when you are in your own cabin
      } else {
        data['status'] = 'away';
        data['cabinOpen'] = false;
      }
    }
    _lastWrite = now;
    // Don't wait for the server: Firebase queues the write and shows it locally at once.
    // If it fails, _sync sees the difference and writes again.
    _doc.update(data).catchError((_) {});
  }
}

class HomeScreen extends StatefulWidget {
  final String facultyId;
  const HomeScreen({super.key, required this.facultyId});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final Presence p = Presence.instance;

  @override
  void initState() {
    super.initState();
    p.start(widget.facultyId); // does nothing if it is already running for this faculty
  }

  Future<void> _logout() async {
    await p.stop();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('facultyId');
    await prefs.remove('role');
    if (!mounted) return;
    Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const PickFacultyScreen()));
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: p, builder: (context, _) => _body(context));

  Widget _body(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final me = p.me;
    final cabinOpen = me?['cabinOpen'] == true;
    final nearby = p.seen.entries.toList()..sort((a, b) => b.value.rssi.compareTo(a.value.rssi));
    final now = DateTime.now();
    final deviceCount = p.allDevices.values.where((t) => now.difference(t) < const Duration(seconds: 30)).length;
    final scanAge = p.scanStartedAt == null ? Duration.zero : now.difference(p.scanStartedAt!);
    final noResults = deviceCount == 0 && scanAge > const Duration(seconds: 10);
    String permText(Permission perm) {
      final st = p.perms[perm];
      if (st == null) return 'checking…';
      if (st.isGranted || st.isLimited) return 'Allowed';
      return st.isPermanentlyDenied ? 'Blocked' : 'Not allowed';
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(me?['name'] ?? 'Kalam Faculty'),
        actions: [
          IconButton(onPressed: _logout, icon: const Icon(Icons.switch_account), tooltip: 'Change faculty'),
        ],
      ),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        if (p.problem != null)
          Card(color: scheme.errorContainer, child: Padding(padding: const EdgeInsets.all(16), child: Text(p.problem!, style: TextStyle(color: scheme.onErrorContainer)))),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('YOU ARE IN', style: TextStyle(fontSize: 12, letterSpacing: 1.2, color: scheme.onSurfaceVariant)),
              const SizedBox(height: 6),
              Text(p.room?.fullLabel ?? 'Not in any room', style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              Text(p.room == null
                  ? 'You are away from your cabin beacon.'
                  : (p.isOwnCabin(p.room!) ? 'This is your cabin.' : 'This is not your saved cabin.'),
                  style: TextStyle(color: scheme.onSurfaceVariant)),
              if (p.room != null && !p.isOwnCabin(p.room!) && p.room!.idx <= 8) ...[
                const SizedBox(height: 10),
                Text('Your saved cabin is ${p.myCabinLabel()}, so students see your door CLOSED. '
                    'If this room is your cabin, tap below.',
                    style: TextStyle(color: scheme.error, fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                FilledButton.icon(
                  onPressed: () => p.makeMyCabin(p.room!),
                  icon: const Icon(Icons.check),
                  label: Text('Make ${p.room!.label} my cabin'),
                ),
              ],
            ]),
          ),
        ),
        const SizedBox(height: 8),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('WHAT STUDENTS SEE', style: TextStyle(fontSize: 12, letterSpacing: 1.2, color: scheme.onSurfaceVariant)),
              const SizedBox(height: 12),
              Row(children: [
                Icon(cabinOpen ? Icons.meeting_room : Icons.door_front_door,
                    size: 44, color: cabinOpen ? Colors.green.shade600 : Colors.red.shade600),
                const SizedBox(width: 14),
                Expanded(child: Text(cabinOpen ? 'Door OPEN\nYou are inside your cabin' : 'Door CLOSED\nYou are not in your cabin',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: cabinOpen ? Colors.green.shade600 : Colors.red.shade600))),
              ]),
              const SizedBox(height: 8),
              Text('Automatic: inside your cabin = OPEN, away from it = CLOSED (about 15 seconds after you leave).',
                  style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
            ]),
          ),
        ),
        const SizedBox(height: 8),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('BEACONS NEARBY', style: TextStyle(fontSize: 12, letterSpacing: 1.2, color: scheme.onSurfaceVariant)),
              const SizedBox(height: 8),
              if (nearby.isEmpty) const Text('Searching… none found yet.'),
              for (final e in nearby)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.bluetooth, color: e.value.rssi >= enterRssi ? Colors.green : scheme.outline),
                  title: Text(parseBeacon(e.key)?.fullLabel ?? e.key),
                  subtitle: Text(e.key),
                  trailing: Text('${e.value.rssi.round()} dBm', style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()])),
                ),
            ]),
          ),
        ),
        const SizedBox(height: 8),
        Card(
          color: noResults ? scheme.errorContainer : null,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('PHONE CHECK', style: TextStyle(fontSize: 12, letterSpacing: 1.2, color: scheme.onSurfaceVariant)),
              const SizedBox(height: 8),
              Text('Kalam beacons heard: $deviceCount'),
              Text('Nearby devices permission: ${permText(Permission.bluetoothScan)}'),
              Text('Location permission: ${permText(Permission.location)}'),
              Text('Location (GPS) switch: ${p.locationServiceOn ? 'On' : 'Off'}'),
              Text('Background mode: ${p.bgRunning ? 'On (works with the phone locked)' : 'Off'}'),
              if (noResults) ...[
                const SizedBox(height: 10),
                const Text('No Kalam beacon heard right now. This is normal when you are away from your cabin. '
                    'If you are inside your cabin and this stays red for over a minute, close the app fully, '
                    'wait 30 seconds and open it again.'),
              ],
              const SizedBox(height: 4),
              Wrap(spacing: 8, runSpacing: 8, children: [
                FilledButton.icon(
                  onPressed: () async { await p.checkPermissions(); await p.startScan(force: true); },
                  icon: const Icon(Icons.refresh), label: const Text('Scan again'),
                ),
                OutlinedButton.icon(
                  onPressed: () => openAppSettings(),
                  icon: const Icon(Icons.settings), label: const Text('App settings'),
                ),
              ]),
            ]),
          ),
        ),
        const SizedBox(height: 12),
        Text('You can lock the phone and keep it in your pocket. Just do not swipe the app away from recent apps.',
            textAlign: TextAlign.center, style: TextStyle(color: scheme.onSurfaceVariant)),
      ]),
    );
  }
}
