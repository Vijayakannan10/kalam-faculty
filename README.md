# Kalam Faculty app (8th Block, Abdul Kalam Block)

The faculty phone listens for ESP32 room beacons (names like `KALAM-4G2`) and
updates the faculty member's room in Firebase automatically. Students see it live.

## Rules used (from the ESP32 test)
- Near the cabin beacon (stronger than -65 dBm): inside, door Open
- Away from it (weaker than -80 dBm or no signal for 15 s): outside, door Closed
- Entering your own cabin marks the cabin door Open; leaving marks it Closed

## Build the APK without installing anything (GitHub)
1. Fill the 4 values in `lib/firebase_config.dart`.
2. Create a new GitHub repository and upload this whole folder (including `.github`).
3. Open the repository's **Actions** tab. The "Build Kalam Faculty APK" run starts by itself.
4. When it shows a green tick, open it and download **kalam-faculty-apk**.
5. Unzip it, copy `app-release.apk` to the Android phone and install it
   (allow "Install unknown apps" when asked).

## Beacon names
| Beacon name   | Room                    |
|---------------|-------------------------|
| KALAM-4G2     | Floor 4, Cabin G2       |
| KALAM-5L3     | Floor 5, Cabin L3       |
| KALAM-304     | Floor 3, Classroom C4   |
| KALAM-2LAB1   | Floor 2, Lab 1          |
| KALAM-6HOD    | Floor 6, HOD room       |

## Firestore data (collection `faculty`)
`name, gender (M/F), cabinFloor, cabinNo, status (cabin/class/meeting/away), floor, idx, cabinOpen, note, updatedAt, source`
