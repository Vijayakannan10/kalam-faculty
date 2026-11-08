// Room model for the 8th Block (Abdul Kalam Block).
// Uses the same room numbers ("idx") as the Faculty Finder page:
//   1–4   Gents cabins G1–G4      5–8   Ladies cabins L1–L4
//   9–18  Classrooms C1–C10       19    Lab 1      20  HOD room (floor 6)
//
// Beacon names (set ROOM_ID in the ESP32 code):
//   KALAM-4G2   Floor 4, Cabin G2
//   KALAM-5L3   Floor 5, Cabin L3
//   KALAM-304   Floor 3, Classroom C4
//   KALAM-2LAB1 Floor 2, Lab 1
//   KALAM-6HOD  Floor 6, HOD room

class Room {
  final String beaconName;
  final int floor;
  final int idx;
  final String label;
  const Room(this.beaconName, this.floor, this.idx, this.label);

  String get fullLabel => 'Floor $floor · $label';
}

Room? parseBeacon(String name) {
  final upper = name.trim().toUpperCase();
  if (!upper.startsWith('KALAM-')) return null;
  final s = upper.substring(6);
  if (s.length < 2) return null;
  final floor = int.tryParse(s[0]);
  if (floor == null || floor < 1 || floor > 6) return null;
  final r = s.substring(1);

  final cabin = RegExp(r'^([GL])([1-4])$').firstMatch(r);
  if (cabin != null) {
    final n = int.parse(cabin.group(2)!);
    final gents = cabin.group(1) == 'G';
    return Room(upper, floor, gents ? n : 4 + n, gents ? 'Cabin G$n' : 'Cabin L$n');
  }
  if (RegExp(r'^\d{2}$').hasMatch(r)) {
    final c = int.parse(r);
    if (c >= 1 && c <= 10) return Room(upper, floor, 8 + c, 'Classroom C$c');
    return null;
  }
  if (r == 'LAB1') return Room(upper, floor, 19, 'Lab 1');
  if (r == 'HOD') return Room(upper, floor, 20, 'HOD Room');
  return null;
}

int cabinIdx(String gender, int cabinNo) => gender == 'F' ? 4 + cabinNo : cabinNo;
