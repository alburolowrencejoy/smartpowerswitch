package com.dnsc.edu.smartpowerswitch

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.widget.RemoteViews

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

        // Read widget data from the Flutter shared preferences bridge.
        // Support both prefixed and unprefixed keys so the widget can load
        // data saved by current and older app builds.
        val prefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        fun readWidgetValue(key: String, fallback: String): String {
            return prefs.getString("flutter.$key", null)
                ?: prefs.getString(key, null)
                ?: fallback
        }

        val deviceId = readWidgetValue("widget_device_id", "No Device")
        val building = readWidgetValue("widget_building", "")
        val room = readWidgetValue("widget_room", "")
        val kwh = readWidgetValue("widget_kwh", "0.000")
        val cost = readWidgetValue("widget_cost", "0.00")
        val voltage = readWidgetValue("widget_voltage", "0.0")
        val power = readWidgetValue("widget_power", "0.0")
        val status = readWidgetValue("widget_status", "offline")
        
        // Set device name and location
        views.setTextViewText(R.id.device_name, deviceId)
        views.setTextViewText(
            R.id.building_room,
            if (building.isNotEmpty() && room.isNotEmpty()) "$building • $room" else "Loading..."
        )
        
        // Set main metrics
        views.setTextViewText(R.id.kwh_value, kwh)
        views.setTextViewText(R.id.cost_value, "₱$cost")
        
        // Set secondary metrics
        views.setTextViewText(R.id.voltage_value, voltage)
        views.setTextViewText(R.id.power_value, power)
        views.setTextViewText(R.id.status_text, if (status == "online") "Online" else "Offline")
        
        // Set status indicator (emoji)
        views.setTextViewText(
            R.id.status_indicator,
            if (status == "online") "🟢" else "🔴"
        )
        
        // Open app when widget is clicked
        val intent = Intent(context, MainActivity::class.java)
        val pendingIntent = PendingIntent.getActivity(
            context, 0, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        views.setOnClickPendingIntent(R.id.widget_layout, pendingIntent)
        
        appWidgetManager.updateAppWidget(appWidgetId, views)
    }
}
