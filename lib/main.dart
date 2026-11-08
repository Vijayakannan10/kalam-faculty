import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'firebase_config.dart';
import 'rooms.dart';

// ---------------- Beacon rules (from the home test with ESP32) ----------------
// Near the beacon: about -45 dBm. Other side / another room: -60 to -80 dBm.
const int enterRssi = -65;          // stronger than this = inside the room
const int leaveRssi = -80;          // weaker than this = left the room
const int switchMargin = 6;         // another room must be this much stronger to switch
const Duration lostAfter = Duration(seconds: 15); // no signal for this long = left
const Duration heartbeat = Duration(minutes: 5);  // keep "updated" fresh while in a room
const String facultyCollection = 'faculty';

Future<void> main() async {
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
  runApp(KalamApp(initError: initError));
}

class KalamApp extends StatelessWidget {
  final String? initError;
  const KalamApp({super.key, this.initError});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Kalam Faculty',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: const Color(0xFF2B4FB8), useMaterial3: true),
      darkTheme: ThemeData(colorSchemeSeed: const Color(0xFF2B4FB8), useMaterial3: true, brightness: Brightness.dark),
      home: initError != null ? MessageScreen(message: initError!) : const StartScreen(),
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
    if (!mounted) return;
    Navigator.of(context).pushReplacement(MaterialPageRoute(
      builder: (_) => id == null ? const PickFacultyScreen() : HomeScreen(facultyId: id),
    ));
  }

  @override
  Widget build(BuildContext context) => const Scaffold(body: Center(child: CircularProgressIndicator()));
}

class PickFacultyScreen extends StatelessWidget {
  const PickFacultyScreen({super.key});

  Future<void> _choose(BuildContext context, String id) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('facultyId', id);
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
                child: Text('Pick your name. This phone will then update your room automatically.'),
              ),
              for (final d in docs)
                ListTile(
                  leading: CircleAvatar(child: Text(_initials(d.data()['name'] ?? '?'))),
                  title: Text(d.data()['name'] ?? 'Faculty'),
                  subtitle: Text('Cabin: Floor ${d.data()['cabinFloor']}, ${d.data()['gender'] == 'F' ? 'L' : 'G'}${d.data()['cabinNo']}'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _choose(context, d.id),
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

class HomeScreen extends StatefulWidget {
  final String facultyId;
  const HomeScreen({super.key, required this.facultyId});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final Map<String, Seen> _seen = {};
  Room? _room;                       // room the app has decided you are in
  Map<String, dynamic>? _me;         // your faculty record
  String? _problem;                  // permission / bluetooth message
  bool _writing = false;
  DateTime? _lastWrite;
  StreamSubscription? _scanSub, _adapterSub, _meSub;
  Timer? _tick;

  DocumentReference<Map<String, dynamic>> get _doc =>
      FirebaseFirestore.instance.collection(facultyCollection).doc(widget.facultyId);

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
    _meSub = _doc.snapshots().listen((s) => setState(() => _me = s.data()));
    _start();
    _tick = Timer.periodic(const Duration(seconds: 2), (_) => _evaluate());
  }

  @override
  void dispose() {
    _tick?.cancel();
    _scanSub?.cancel();
    _adapterSub?.cancel();
    _meSub?.cancel();
    FlutterBluePlus.stopScan();
    WakelockPlus.disable();
    super.dispose();
  }

  Future<void> _start() async {
    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();
    final denied = statuses.entries.where((e) => e.value.isPermanentlyDenied || e.value.isDenied).map((e) => e.key).toList();
    if (denied.contains(Permission.bluetoothScan) && denied.contains(Permission.locationWhenInUse)) {
      setState(() => _problem = 'Allow Bluetooth and Location for this app in phone Settings, then reopen it.');
      return;
    }

    _adapterSub = FlutterBluePlus.adapterState.listen((state) async {
      if (state == BluetoothAdapterState.on) {
        setState(() => _problem = null);
        await _startScan();
      } else {
        setState(() => _problem = 'Turn on Bluetooth to detect your room.');
      }
    });
    try { await FlutterBluePlus.turnOn(); } catch (_) {}
  }

  Future<void> _startScan() async {
    await _scanSub?.cancel();
    _scanSub = FlutterBluePlus.onScanResults.listen((results) {
      final now = DateTime.now();
      for (final r in results) {
        final name = r.advertisementData.advName.isNotEmpty ? r.advertisementData.advName : r.device.platformName;
        if (!name.toUpperCase().startsWith('KALAM-')) continue;
        final s = _seen[name];
        if (s == null) {
          _seen[name] = Seen(r.rssi.toDouble(), now);
        } else {
          s.rssi = s.rssi * 0.7 + r.rssi * 0.3; // smooth the jumpy signal
          s.last = now;
        }
      }
    });
    try {
      await FlutterBluePlus.startScan(continuousUpdates: true, androidScanMode: AndroidScanMode.lowLatency);
    } catch (e) {
      setState(() => _problem = 'Could not start Bluetooth scan: $e');
    }
  }

  void _evaluate() {
    final now = DateTime.now();
    _seen.removeWhere((_, s) => now.difference(s.last) > const Duration(seconds: 30));

    // strongest recent beacon
    MapEntry<String, Seen>? best;
    for (final e in _seen.entries) {
      if (now.difference(e.value.last) > lostAfter) continue;
      if (parseBeacon(e.key) == null) continue;
      if (best == null || e.value.rssi > best.value.rssi) best = e;
    }

    Room? next = _room;
    if (_room == null) {
      if (best != null && best.value.rssi >= enterRssi) next = parseBeacon(best.key);
    } else {
      final cur = _seen[_room!.beaconName];
      final curOk = cur != null && now.difference(cur.last) <= lostAfter && cur.rssi >= leaveRssi;
      if (!curOk) {
        next = (best != null && best.value.rssi >= enterRssi) ? parseBeacon(best.key) : null;
      } else if (best != null && best.key != _room!.beaconName &&
          best.value.rssi >= enterRssi && best.value.rssi > cur.rssi + switchMargin) {
        next = parseBeacon(best.key);
      }
    }

    final changed = next?.beaconName != _room?.beaconName;
    setState(() => _room = next);
    if (changed) {
      _push(next);
    } else if (_room != null && (_lastWrite == null || now.difference(_lastWrite!) > heartbeat)) {
      _push(_room, heartbeatOnly: true);
    }
  }

  bool _isOwnCabin(Room r) {
    final me = _me;
    if (me == null) return false;
    return r.floor == (me['cabinFloor'] as num?)?.toInt() &&
        r.idx == cabinIdx(me['gender'] ?? 'M', (me['cabinNo'] as num?)?.toInt() ?? 0);
  }

  Future<void> _push(Room? room, {bool heartbeatOnly = false}) async {
    if (_writing) return;
    _writing = true;
    final now = DateTime.now();
    final data = <String, dynamic>{'updatedAt': now.millisecondsSinceEpoch, 'source': 'beacon'};
    if (!heartbeatOnly) {
      if (room != null) {
        final own = _isOwnCabin(room);
        data.addAll({'status': own ? 'cabin' : 'class', 'floor': room.floor, 'idx': room.idx});
        if (own) data['cabinOpen'] = true;
      } else {
        data['status'] = 'away';
        data['cabinOpen'] = false;
      }
    }
    try {
      await _doc.update(data);
      _lastWrite = now;
    } catch (_) {
      // try again on the next change or heartbeat
    } finally {
      _writing = false;
    }
  }

  Future<void> _setCabin(bool open) async {
    try { await _doc.update({'cabinOpen': open, 'updatedAt': DateTime.now().millisecondsSinceEpoch}); } catch (_) {}
  }

  Future<void> _logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('facultyId');
    if (!mounted) return;
    Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const PickFacultyScreen()));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final me = _me;
    final cabinOpen = me?['cabinOpen'] == true;
    final nearby = _seen.entries.toList()..sort((a, b) => b.value.rssi.compareTo(a.value.rssi));

    return Scaffold(
      appBar: AppBar(
        title: Text(me?['name'] ?? 'Kalam Faculty'),
        actions: [IconButton(onPressed: _logout, icon: const Icon(Icons.switch_account), tooltip: 'Change faculty')],
      ),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        if (_problem != null)
          Card(color: scheme.errorContainer, child: Padding(padding: const EdgeInsets.all(16), child: Text(_problem!, style: TextStyle(color: scheme.onErrorContainer)))),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('YOU ARE IN', style: TextStyle(fontSize: 12, letterSpacing: 1.2, color: scheme.onSurfaceVariant)),
              const SizedBox(height: 6),
              Text(_room?.fullLabel ?? 'Not in any room', style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              Text(_room == null
                  ? 'Walk into a room with a Kalam beacon and it will update by itself.'
                  : (_isOwnCabin(_room!) ? 'Your own cabin. Students see you as "In cabin".' : 'Students see you as "Taking class" here.'),
                  style: TextStyle(color: scheme.onSurfaceVariant)),
            ]),
          ),
        ),
        const SizedBox(height: 8),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('MY CABIN DOOR', style: TextStyle(fontSize: 12, letterSpacing: 1.2, color: scheme.onSurfaceVariant)),
              const SizedBox(height: 12),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: true, label: Text('Open'), icon: Icon(Icons.door_front_door_outlined)),
                  ButtonSegment(value: false, label: Text('Closed'), icon: Icon(Icons.lock_outline)),
                ],
                selected: {cabinOpen},
                onSelectionChanged: (s) => _setCabin(s.first),
              ),
              const SizedBox(height: 8),
              Text('Opens by itself when you enter your cabin and closes when you leave. You can change it any time.',
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
        const SizedBox(height: 12),
        Text('Keep this app open during college hours. Students see your room live.',
            textAlign: TextAlign.center, style: TextStyle(color: scheme.onSurfaceVariant)),
      ]),
    );
  }
}
