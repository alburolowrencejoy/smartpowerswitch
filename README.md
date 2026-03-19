# SmartPowerSwitch — Flutter App

IoT Energy Monitoring & Control System for Davao del Norte State College (DNSC) Campus.


## **Download**
https://www.mediafire.com/file/k6mgs9a87plq3n7/app-release.apk/file
---

## Project Structure

```
lib/
├── main.dart                        ← Entry point + routing
├── theme/
│   └── app_colors.dart              ← All color constants
└── screens/
    ├── login_screen.dart            ← Login with Firebase Auth
    ├── dashboard_screen.dart        ← Energy overview + building list
    ├── building_floor_screen.dart   ← Floor tabs + device grid
    ├── device_detail_screen.dart    ← PZEM readings + relay toggle
    ├── history_screen.dart          ← 30d/12w/12mo/3yr charts + CSV export
    ├── notifications_screen.dart    ← Alerts (high consumption, offline)
    └── settings_screen.dart        ← Admin: rate, users, account
```

---

## Color Palette

| Name         | Hex       | Usage                         |
|--------------|-----------|-------------------------------|
| greenDark    | #1A5C35   | Primary, headers, buttons     |
| greenMid     | #2E9E52   | Accents, active states        |
| greenLight   | #6ECB8A   | Highlights, badges            |
| greenPale    | #C2EDD0   | Backgrounds, cards            |

---

## Setup

### 1. Install Flutter
https://docs.flutter.dev/get-started/install

### 2. Create Firebase Project
- Go to https://console.firebase.google.com
- Create project: `SmartPowerSwitch`
- Enable: Authentication (Email/Password) + Realtime Database

### 3. Connect Firebase to Flutter
```bash
dart pub global activate flutterfire_cli
flutterfire configure
```
This generates `firebase_options.dart` — add it to `lib/`.

Then update `main.dart`:
```dart
import 'firebase_options.dart';

await Firebase.initializeApp(
  options: DefaultFirebaseOptions.currentPlatform,
);
```

### 4. Install dependencies
```bash
flutter pub get
```

### 5. Run the app
```bash
flutter run
```

---

## Screen Navigation Flow

```
LoginScreen
    └── DashboardScreen
          ├── BuildingFloorScreen
          │     └── DeviceDetailScreen
          ├── HistoryScreen
          ├── NotificationsScreen
          └── SettingsScreen (admin only)
```

---

## Buildings & Devices

| Building | Floors | Devices |
|----------|--------|---------|
| IC       | 2      | 6       |
| ILEGG    | 2      | 6       |
| ITED     | 2      | 6       |
| IAAS     | 1      | 3       |
| ADMIN    | 1      | 3       |
| **Total**|        | **24**  |

3 utilities per floor: Lights (Relay), Outlets (Relay), AC (Contactor)

---

## User Roles

- **Admin** — full control: relay toggle, settings, user management
- **Faculty** — view only: dashboard, readings, history

---

## Firebase Database Structure

See the Firebase setup guide for the full JSON import.
