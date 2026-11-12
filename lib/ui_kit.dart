import 'package:flutter/material.dart';

// Shared look for Kalam Faculty (blue) and Kalam Student (green).
const kFacultyBlue = Color(0xFF2B4FB8);
const kFacultyBlue2 = Color(0xFF3D6BE0);
const kStudentGreen = Color(0xFF17834A);
const kStudentGreen2 = Color(0xFF22A35A);
const kOpen = Color(0xFF1E9E55);
const kBusy = Color(0xFFC77D0A);
const kClosed = Color(0xFFD0402F);

ThemeData kalamTheme(Color seed, Brightness b) {
  final scheme = ColorScheme.fromSeed(seedColor: seed, brightness: b);
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: b == Brightness.light ? const Color(0xFFF4F6FA) : const Color(0xFF10141B),
    cardTheme: CardTheme(
      elevation: 0,
      color: b == Brightness.light ? Colors.white : const Color(0xFF1A202B),
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    chipTheme: ChipThemeData(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20))),
  );
}

enum DoorState { inside, busy, out }

DoorState doorOf(Map<String, dynamic> f) {
  if (f['cabinOpen'] != true) return DoorState.out;
  return f['busy'] == true ? DoorState.busy : DoorState.inside;
}

Color doorColor(DoorState s) => s == DoorState.inside ? kOpen : (s == DoorState.busy ? kBusy : kClosed);

String doorText(DoorState s) =>
    s == DoorState.inside ? 'Inside · Door OPEN' : (s == DoorState.busy ? 'Inside · Busy' : 'Went out · Door CLOSED');

IconData doorIcon(DoorState s) => s == DoorState.out ? Icons.door_front_door : Icons.meeting_room;

String initialsOf(String name) {
  final parts = name
      .replaceAll(RegExp(r'^(Dr|Mr|Mrs|Ms|Prof)\.?\s*', caseSensitive: false), '')
      .split(RegExp(r'[\s.]+'))
      .where((w) => w.isNotEmpty)
      .toList();
  if (parts.isEmpty) return '?';
  return parts.length == 1 ? parts.first[0].toUpperCase() : (parts[parts.length - 2][0] + parts.last[0]).toUpperCase();
}

const _avatarColors = [Color(0xFF2B4FB8), Color(0xFF0F7A6C), Color(0xFF9A4A12), Color(0xFF7A3FB8), Color(0xFFB8335A), Color(0xFF3D6B1F)];
Color avatarColor(String id) {
  var h = 0;
  for (final c in id.codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  return _avatarColors[h % _avatarColors.length];
}

String hm(int? ms) {
  if (ms == null) return '';
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
  return '$h:${d.minute.toString().padLeft(2, '0')} ${d.hour < 12 ? 'AM' : 'PM'}';
}

String agoText(int? ms) {
  if (ms == null) return '';
  final m = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(ms)).inMinutes;
  if (m < 1) return 'just now';
  if (m < 60) return '$m min ago';
  if (m < 1440) return '${m ~/ 60} hr ago';
  return '${m ~/ 1440} days ago';
}

String todayKey() {
  final d = DateTime.now();
  return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

/// Today's in/out events for a faculty record: [(time ms, came in?)], oldest first.
List<(int, bool)> todayEvents(Map<String, dynamic> f) {
  if (f['todayDate'] != todayKey()) return [];
  final raw = f['today'];
  if (raw is! List) return [];
  final out = <(int, bool)>[];
  for (final e in raw) {
    if (e is Map && e['t'] is num) out.add(((e['t'] as num).toInt(), e['in'] == true));
  }
  out.sort((a, b) => a.$1.compareTo(b.$1));
  return out;
}

/// Minutes spent inside the cabin today, from the in/out events.
int minutesInCabinToday(Map<String, dynamic> f) {
  final ev = todayEvents(f);
  var total = 0;
  int? since;
  for (final (t, inside) in ev) {
    if (inside) {
      since ??= t;
    } else if (since != null) {
      total += t - since;
      since = null;
    }
  }
  if (since != null && f['cabinOpen'] == true) total += DateTime.now().millisecondsSinceEpoch - since;
  return total ~/ 60000;
}

String durationText(int minutes) {
  if (minutes < 60) return '${minutes}m';
  return '${minutes ~/ 60}h ${(minutes % 60).toString().padLeft(2, '0')}m';
}

class Avatar extends StatelessWidget {
  final String id;
  final String name;
  final double size;
  const Avatar({super.key, required this.id, required this.name, this.size = 44});
  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: avatarColor(id), borderRadius: BorderRadius.circular(size * 0.3)),
        child: Text(initialsOf(name),
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: size * 0.36)),
      );
}

class SectionLabel extends StatelessWidget {
  final String text;
  const SectionLabel(this.text, {super.key});
  @override
  Widget build(BuildContext context) => Text(text.toUpperCase(),
      style: TextStyle(
          fontSize: 11.5, letterSpacing: 1.1, fontWeight: FontWeight.w800, color: Theme.of(context).colorScheme.onSurfaceVariant));
}

/// The coloured gradient band at the top of both apps.
class GradientHeader extends StatelessWidget {
  final List<Color> colors;
  final Widget child;
  const GradientHeader({super.key, required this.colors, required this.child});
  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        decoration: BoxDecoration(
          gradient: LinearGradient(colors: colors, begin: Alignment.topLeft, end: Alignment.bottomRight),
          borderRadius: const BorderRadius.vertical(bottom: Radius.circular(28)),
        ),
        padding: EdgeInsets.fromLTRB(20, MediaQuery.of(context).padding.top + 14, 20, 22),
        child: DefaultTextStyle.merge(style: const TextStyle(color: Colors.white), child: child),
      );
}
