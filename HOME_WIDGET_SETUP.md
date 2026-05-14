# Home Screen Widget Setup Guide

## Overview
The Smart Power Switch app includes home screen widget support, allowing users to see real-time energy usage directly from their phone's home screen without opening the app.

**Supported:**
- Android (via `flutter_home_widget` package)
- iOS (via `flutter_home_widget` package with WidgetKit)

## Features
- 🔋 Real-time kWh and cost display
- ⚡ Voltage status with brownout/surge alerts
- 📊 Power consumption in Watts
- 🟢 Online/Offline status indicator
- 🔄 Updates whenever you view a device in the app

## Installation Steps

### 1. Get Dependencies
```bash
flutter pub get
```

The `flutter_home_widget: ^1.0.0` package is already added to `pubspec.yaml`.

### 2. Android Configuration

#### Step 2a: Update AndroidManifest.xml
Add to `android/app/src/main/AndroidManifest.xml`:

```xml
<!-- Inside <manifest> -->
<receiver
    android:name="com.example.smart_power_switch.SmartPowerSwitchWidget"
    android:label="@string/app_name"
    android:exported="true">
    <intent-filter>
        <action android:name="android.appwidget.action.APPWIDGET_UPDATE" />
    </intent-filter>
    <meta-data
        android:name="android.appwidget.provider"
        android:resource="@xml/smart_power_switch_widget_provider" />
</receiver>
```

#### Step 2b: Create Widget Info XML
Create `android/app/src/main/res/xml/smart_power_switch_widget_provider.xml`:

```xml
<?xml version="1.0" encoding="utf-8"?>
<appwidget-provider xmlns:android="http://schemas.android.com/apk/res/android"
    android:minWidth="110dp"
    android:minHeight="110dp"
    android:updatePeriodMillis="1800000"
    android:resizeMode="horizontal|vertical"
    android:widgetCategory="home_screen"
    android:previewImage="@drawable/widget_preview">
</appwidget-provider>
```

#### Step 2c: Create Widget Receiver Class
Create `android/app/src/main/kotlin/com/example/smart_power_switch/SmartPowerSwitchWidget.kt`:

```kotlin
package com.example.smart_power_switch

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.widget.RemoteViews
import android.content.Intent

class SmartPowerSwitchWidget : AppWidgetProvider() {
    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray
    ) {
        for (appWidgetId in appWidgetIds) {
            updateAppWidget(context, appWidgetManager, appWidgetId)
        }
    }

    private fun updateAppWidget(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetId: Int
    ) {
        val views = RemoteViews(context.packageName, R.layout.widget_layout)
        
        // Get widget data (shared with Flutter app via SharedPreferences)
        val prefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        val deviceId = prefs.getString("flutter.last_device_id", "No Device") ?: "No Device"
        val kwh = prefs.getString("flutter.last_device_kwh", "0.000") ?: "0.000"
        val cost = prefs.getString("flutter.last_device_cost", "0.00") ?: "0.00"
        val voltage = prefs.getString("flutter.last_device_voltage", "0.0") ?: "0.0"
        val status = prefs.getString("flutter.last_device_status", "offline") ?: "offline"
        
        views.setTextViewText(R.id.device_name, deviceId)
        views.setTextViewText(R.id.kwh_value, "$kwh kWh")
        views.setTextViewText(R.id.cost_value, "₱$cost")
        views.setTextViewText(R.id.voltage_value, "$voltage V")
        views.setTextViewText(R.id.status_text, if (status == "online") "🟢 Online" else "🔴 Offline")
        
        // Open app when widget is clicked
        val intent = Intent(context, MainActivity::class.java)
        val pendingIntent = PendingIntent.getActivity(context, 0, intent, 
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        views.setOnClickPendingIntent(R.id.widget_container, pendingIntent)
        
        appWidgetManager.updateAppWidget(appWidgetId, views)
    }
}
```

#### Step 2d: Create Widget Layout XML
Create `android/app/src/main/res/layout/widget_layout.xml`:

```xml
<?xml version="1.0" encoding="utf-8"?>
<LinearLayout xmlns:android="http://schemas.android.com/apk/res/android"
    android:id="@+id/widget_container"
    android:layout_width="match_parent"
    android:layout_height="match_parent"
    android:background="@drawable/widget_background"
    android:orientation="vertical"
    android:padding="12dp">

    <TextView
        android:id="@+id/device_name"
        android:layout_width="match_parent"
        android:layout_height="wrap_content"
        android:text="Device"
        android:textColor="#FFFFFF"
        android:textSize="14sp"
        android:textStyle="bold" />

    <LinearLayout
        android:layout_width="match_parent"
        android:layout_height="wrap_content"
        android:layout_marginTop="8dp"
        android:orientation="horizontal">

        <LinearLayout
            android:layout_width="0dp"
            android:layout_height="wrap_content"
            android:layout_weight="1"
            android:orientation="vertical">

            <TextView
                android:layout_width="wrap_content"
                android:layout_height="wrap_content"
                android:text="Energy"
                android:textColor="#FFFFFF99"
                android:textSize="10sp" />

            <TextView
                android:id="@+id/kwh_value"
                android:layout_width="wrap_content"
                android:layout_height="wrap_content"
                android:text="0.000 kWh"
                android:textColor="#FFFFFF"
                android:textSize="12sp"
                android:textStyle="bold" />
        </LinearLayout>

        <LinearLayout
            android:layout_width="0dp"
            android:layout_height="wrap_content"
            android:layout_weight="1"
            android:orientation="vertical">

            <TextView
                android:layout_width="wrap_content"
                android:layout_height="wrap_content"
                android:text="Cost"
                android:textColor="#FFFFFF99"
                android:textSize="10sp" />

            <TextView
                android:id="@+id/cost_value"
                android:layout_width="wrap_content"
                android:layout_height="wrap_content"
                android:text="₱0.00"
                android:textColor="#FFFFFF"
                android:textSize="12sp"
                android:textStyle="bold" />
        </LinearLayout>
    </LinearLayout>

    <LinearLayout
        android:layout_width="match_parent"
        android:layout_height="wrap_content"
        android:layout_marginTop="8dp"
        android:orientation="horizontal">

        <LinearLayout
            android:layout_width="0dp"
            android:layout_height="wrap_content"
            android:layout_weight="1"
            android:orientation="vertical">

            <TextView
                android:layout_width="wrap_content"
                android:layout_height="wrap_content"
                android:text="Voltage"
                android:textColor="#FFFFFF99"
                android:textSize="10sp" />

            <TextView
                android:id="@+id/voltage_value"
                android:layout_width="wrap_content"
                android:layout_height="wrap_content"
                android:text="0.0 V"
                android:textColor="#FFFFFF"
                android:textSize="12sp"
                android:textStyle="bold" />
        </LinearLayout>

        <LinearLayout
            android:layout_width="0dp"
            android:layout_height="wrap_content"
            android:layout_weight="1"
            android:orientation="vertical">

            <TextView
                android:id="@+id/status_text"
                android:layout_width="wrap_content"
                android:layout_height="wrap_content"
                android:text="🔴 Offline"
                android:textColor="#FFFFFF"
                android:textSize="12sp"
                android:textStyle="bold" />
        </LinearLayout>
    </LinearLayout>
</LinearLayout>
```

### 3. iOS Configuration

#### Step 3a: Create Widget Extension Target
In Xcode (open `ios/Runner.xcworkspace`):
1. File → New → Target → Widget Extension
2. Name it `SmartPowerSwitchWidget`
3. Set bundle ID to `com.example.smartpowerswitch.SmartPowerSwitchWidget`

#### Step 3b: Create Widget Code
Replace `ios/SmartPowerSwitchWidget/SmartPowerSwitchWidget.swift`:

```swift
import WidgetKit
import SwiftUI
import Intents

struct Provider: IntentTimelineProvider {
    func placeholder(in context: Context) -> SimpleEntry {
        SimpleEntry(date: Date(), configuration: ConfigurationIntent(), kwh: "0.000", cost: "0.00", voltage: "0.0", status: "offline")
    }

    func getSnapshot(for configuration: ConfigurationIntent, in context: Context, completion: @escaping (SimpleEntry) -> ()) {
        let entry = SimpleEntry(date: Date(), configuration: configuration, kwh: "0.000", cost: "0.00", voltage: "0.0", status: "offline")
        completion(entry)
    }

    func getTimeline(for configuration: ConfigurationIntent, in context: Context, completion: @escaping (Timeline<Entry>) -> ()) {
        var entries: [SimpleEntry] = []

        let userDefaults = UserDefaults(suiteName: "group.com.example.smartpowerswitch")
        let kwh = userDefaults?.string(forKey: "widget_kwh") ?? "0.000"
        let cost = userDefaults?.string(forKey: "widget_cost") ?? "0.00"
        let voltage = userDefaults?.string(forKey: "widget_voltage") ?? "0.0"
        let status = userDefaults?.string(forKey: "widget_status") ?? "offline"

        let entry = SimpleEntry(date: Date(), configuration: configuration, kwh: kwh, cost: cost, voltage: voltage, status: status)
        entries.append(entry)

        let timeline = Timeline(entries: entries, policy: .after(Date(timeIntervalSinceNow: 60)))
        completion(timeline)
    }
}

struct SimpleEntry: TimelineEntry {
    let date: Date
    let configuration: ConfigurationIntent
    let kwh: String
    let cost: String
    let voltage: String
    let status: String
}

struct SmartPowerSwitchWidgetEntryView: View {
    var entry: Provider.Entry

    var body: some View {
        ZStack {
            LinearGradient(
                gradient: Gradient(colors: [Color(red: 0.12, green: 0.53, blue: 0.90), Color(red: 0.08, green: 0.39, blue: 0.75)]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Power Monitor")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)

                    Spacer()

                    Text(entry.status == "online" ? "🟢" : "🔴")
                        .font(.system(size: 12))
                }

                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Energy")
                            .font(.system(size: 10))
                            .foregroundColor(.white).opacity(0.7)
                        Text("\(entry.kwh) kWh")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.white)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Cost")
                            .font(.system(size: 10))
                            .foregroundColor(.white).opacity(0.7)
                        Text("₱\(entry.cost)")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.white)
                    }
                }

                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Voltage")
                            .font(.system(size: 10))
                            .foregroundColor(.white).opacity(0.7)
                        Text("\(entry.voltage) V")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.white)
                    }

                    Spacer()
                }
            }
            .padding(12)
        }
    }
}

@main
struct SmartPowerSwitchWidget: Widget {
    let kind: String = "SmartPowerSwitchWidget"

    var body: some WidgetConfiguration {
        IntentConfiguration(kind: kind, intent: ConfigurationIntent.self, provider: Provider()) { entry in
            SmartPowerSwitchWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Smart Power Switch")
        .description("View real-time energy usage")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
```

### 4. Integration in Flutter

The widget updates are already integrated:

1. **Automatic Initialization** — `HomeWidgetService.initialize()` runs when app starts (in `main.dart`)

2. **Device Selection** — When you open a device detail screen, it saves the device ID

3. **Real-time Updates** — Every time device data updates from Firebase, the widget refreshes

## How It Works

### Data Flow
```
ESP32 (PZEM) → Firebase → Flutter App
                            ↓
                      HomeWidgetService
                            ↓
                    SharedPreferences
                            ↓
                    Home Screen Widget
```

### Update Frequency
- **Device changes:** Every 3 seconds (when PZEM sends new readings)
- **App updates widget:** Automatically when listening to device
- **Widget refreshes:** Android (1800s default), iOS (60s in code)

## Testing

### Android
1. Build app: `flutter build apk --debug`
2. Install: `flutter install`
3. Long-press home screen → Add widget → "Smart Power Switch"
4. Open a device in the app, then check the widget

### iOS
1. Build app: `flutter run`
2. Open app and navigate to a device
3. Add WidgetKit widget to home screen from Edit button
4. Widget should show real-time data

## Troubleshooting

**Widget not updating?**
- Ensure you opened a device detail screen (saves device selection)
- Check SharedPreferences data is being saved
- Restart app and add widget again

**Widget shows "offline"?**
- Check Firebase connectivity
- Verify ESP32 is sending data (check device in app)
- Check the device status in `/devices/{deviceId}`

**Android widget doesn't appear?**
- Verify `AndroidManifest.xml` changes
- Check `widget_layout.xml` exists in `res/layout/`
- Check `smart_power_switch_widget_provider.xml` exists in `res/xml/`

**iOS widget not showing data?**
- Verify App Groups entitlement is enabled
- Check bundle ID matches in code
- Verify `UserDefaults(suiteName:)` uses correct app group

## Key Files Modified/Created

✅ `pubspec.yaml` — Added `flutter_home_widget: ^1.0.0`
✅ `lib/services/home_widget_service.dart` — Widget update logic
✅ `lib/main.dart` — Initialize widget service
✅ `lib/screens/device_detail_screen.dart` — Save device selection and trigger updates
✅ `android/app/src/main/AndroidManifest.xml` — Register widget receiver
✅ `android/app/src/main/res/xml/smart_power_switch_widget_provider.xml` — Widget configuration
✅ `android/app/src/main/kotlin/com/example/smart_power_switch/SmartPowerSwitchWidget.kt` — Widget implementation
✅ `android/app/src/main/res/layout/widget_layout.xml` — Widget UI
✅ `ios/SmartPowerSwitchWidget/SmartPowerSwitchWidget.swift` — iOS widget

