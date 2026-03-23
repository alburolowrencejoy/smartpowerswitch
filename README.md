# 🔌 SmartPowerSwitch

> IoT Energy Monitoring & Control System for **Davao del Norte State College (DNSC)** Campus

Built with Flutter + Firebase Realtime Database. Monitors energy consumption and controls utilities across 5 campus buildings using ESP32 devices with PZEM-004T energy meters.

---

## 📥 Download

| File | Link |
|------|------|
| 📱 Android APK | [Download app-release.apk](https://www.mediafire.com/file/w62gsxvk3cpghja/app-release.apk/file) |
| 🔑 firebase_options.dart | [Download](https://www.mediafire.com/file/qote6y3jsvbqv8f/firebase_options.dart/file) |
| 🔑 google-services.json | [Download](https://www.mediafire.com/file/fy2cukv42pqov12/google-services.json/file) |

> ⚠️ The key files (`firebase_options.dart` and `google-services.json`) are **not included in this repo** for security reasons. Download them from the links above and place them in the correct directories before running the app.

---

## 🚀 Team Setup Guide

Follow these steps in order to get the app running on your machine.

### Step 1 — Prerequisites

Make sure you have the following installed:

- [Flutter SDK](https://docs.flutter.dev/get-started/install) (3.x or higher)
- [Android Studio](https://developer.android.com/studio) with NDK `27.0.12077973`
- [VS Code](https://code.visualstudio.com/) (recommended editor)
- [Git](https://git-scm.com/)
- [Firebase CLI](https://firebase.google.com/docs/cli) *(only needed for web deployment)*

---

### Step 2 — Clone the Repository

```bash
git clone https://github.com/alburolowrencejoy/smartpowerswitch.git
cd smartpowerswitch
```

---

### Step 3 — Add the Secret Key Files

These files are **not in the repo**. Download them from the links above and place them here:

| File | Where to put it |
|------|-----------------|
| `firebase_options.dart` | `lib/firebase_options.dart` |
| `google-services.json` | `android/app/google-services.json` |

---

### Step 4 — Install Dependencies

```bash
flutter pub get
```

---

### Step 5 — Run the App

**On Android (connected device or emulator):**
```bash
flutter run -d RMX3151 --release
```

**On Chrome (web):**
```bash
flutter run -d chrome
```

**Build APK:**
```bash
flutter build apk --release
```
APK will be at: `build/app/outputs/flutter-apk/app-release.apk`

**Deploy to Web:**
```bash
flutter build web
firebase deploy
```

---

### Step 6 — Firebase Setup (first time only)

1. Go to [Firebase Console](https://console.firebase.google.com/project/smartpowerswitch-e90d0/overview)
2. Make sure **Authentication** (Email/Password) and **Realtime Database** are enabled
3. Import the database JSON — go to **Realtime Database → ⋮ → Import JSON**
4. Set the **Security Rules** under **Realtime Database → Rules**

---

## 🔐 Test Accounts

| Role | Email | Password |
|------|-------|----------|
| Admin | admin@dnsc.edu.ph | *(ask team lead)* |
| Faculty | faculty@dnsc.edu.ph | *(ask team lead)* |

---

## 🎨 Color Palette

| Name | Hex | Usage |
|------|-----|-------|
| greenDark | `#1A5C35` | Headers, buttons, primary |
| greenMid | `#2E9E52` | Accents, active states |
| greenLight | `#6ECB8A` | Highlights, badges |
| greenPale | `#C2EDD0` | Backgrounds, cards |

---

## 🏫 Buildings & Devices

| Building | Code | Floors |
|----------|------|--------|
| Institute of Computing | IC | 2 |
| Institute of Leadership & Good Governance | ILEGG | 2 |
| Institute of Teachers Education | ITED | 2 |
| Institute of Aquatic Science | IAAS | 1 |
| Administrator Building | ADMIN | 1 |

---

## 👥 User Roles

| Role | Permissions |
|------|-------------|
| **Admin** | Relay control, add/remove devices & rooms, manage users, change electricity rate |
| **Faculty** | View dashboard, energy readings, history — no control |

---

## 📁 Project Structure

```
lib/
├── main.dart                        ← Entry point + routing
├── theme/
│   └── app_colors.dart              ← Color constants
└── screens/
    ├── login_screen.dart            ← Firebase Auth login
    ├── dashboard_screen.dart        ← Energy overview + buildings
    ├── building_floor_screen.dart   ← Floor tabs + rooms + devices
    ├── device_detail_screen.dart    ← PZEM readings + relay toggle
    ├── history_screen.dart          ← Analytics + line chart + CSV export
    ├── notifications_screen.dart    ← Alerts (high consumption, offline)
    └── settings_screen.dart         ← Admin: rate, users, account
```

---

## 🗺️ Screen Navigation

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

## 🔥 Firebase Structure

```
smartpowerswitch-e90d0/
├── users/              ← User roles (admin / faculty)
├── buildings/          ← Floor data, rooms, devices per building
├── devices/            ← Live PZEM readings from ESP32
├── master_devices/     ← Device registry & assignment
├── history/            ← Energy history (daily/weekly/monthly/yearly)
└── settings/           ← Electricity rate (₱/kWh)
```

---

## ⚠️ Files NOT in This Repo

These files contain secret keys and must **never be committed to GitHub**:

```
lib/firebase_options.dart
android/app/google-services.json
ios/Runner/GoogleService-Info.plist
```

They are listed in `.gitignore`. Download them from the links at the top of this README.

---

## 🛠️ Tech Stack

- **Flutter** — cross-platform mobile & web app
- **Firebase Auth** — user authentication
- **Firebase Realtime Database** — live data sync
- **ESP32** — IoT controller *(firmware coming soon)*
- **PZEM-004T** — energy meter sensor
- **Twilio SMS + SendGrid** — notifications *(planned)*
