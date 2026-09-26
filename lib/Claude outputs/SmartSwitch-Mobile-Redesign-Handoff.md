# SmartSwitch — Mobile UI Redesign: Session Handoff

Owner: Ransu (DNSC IT capstone — SmartPowerSwitch)
Session dates: Sep 24–25, 2026
Purpose of this doc: everything decided and built in this session, screen by screen, so the next session can continue without re-deriving anything.

---

## 0. Where things are

| Thing | Location | Notes |
|---|---|---|
| **Interactive preview (latest)** | claude.ai artifact **"SmartSwitch Phone Prototype"** — `https://claude.ai/artifact/3h7XcWJEHDSusZM2T8Sbxh` (version 36) | Two live phones side by side. Private until shared. |
| **Downloadable preview** | `smartswitch-mobile-preview.html` (delivered with this doc) | Same page, standalone. Open in Chrome. Icons/fonts load from Google Fonts, so needs internet. |
| **Design-system artifact** | `https://claude.ai/code/artifact/68ca48f8-4f26-4d1e-a509-017db26b42bc` ("SmartSwitch Mobile") | Built early in the session (tokens, type scale, first-draft screen cards). **Outdated** vs. the preview — the preview is the source of truth. |
| **Flutter source (read-only this session)** | `D:\Downloads\smartpowerswitch\lib` | Nothing in the Flutter project was changed. All work is in the preview. |
| **Campus map image** | `D:\Downloads\assets\images\campus_map.png` (354×496 px) | Used in the preview map (embedded as data URI). |

**Important:** no Dart files were written. Everything below is a design + interactive prototype that still has to be implemented in Flutter.

---

## 1. Audit of the original mobile UI (why we redesigned)

Findings from `lib/screens/mobile/*` and `lib/screens/shared/*`:

| Problem | Evidence | Fix adopted |
|---|---|---|
| Text too small | 90 uses of `fontSize: 9–10`, 55 of `11` | 12sp floor; body 15, secondary 14 |
| Muted text unreadable | `AppColors.textMuted #7AAA8A` = 2.6:1 on white, used 118× | Darker secondary text (see §3) |
| Orange used as text | `AppColors.warning #E8922A` = 2.5:1 | `warning-text #A15208` for text; orange only as fill |
| White on greenMid | 3.4:1 | Primary buttons use green-dark (8.0:1) |
| Key pages hidden | Notifications / Manage Users / Settings / Logout in burger `PopupMenuButton` | Bell with badge in top bar + **More** tab |
| Mobile missing web features | Web has Overview KPIs, Building Load, Analytics filter bar, Forecast (ARIMA/XGBoost/LSTM), Breakdown, History panel | All ported (see §6) |
| Busy scaffold | `scaffoldBackgroundColor: greenPale #C2EDD0` | Pure white background, flat layout |

Font: **Roboto** (already bundled via `AppFonts.family`, used on web too — `lib/theme/app_fonts.dart`, enforced by `test/ui_conventions_test.dart`). Kept.

---

## 2. Navigation (final)

Bottom nav mirrors the web side nav.

**Campus admin (super admin):** `Home · Devices · Analytics · Automation · More`
- Home = web Dashboard/Overview
- Devices = web Devices **+** Map (List | Map toggle at top)
- Analytics = web Analytics (Usage | Forecast toggle)
- Automation
- More = profile, Users, Settings, Notifications, About, Sign out

**Institute admin:** `Home · Devices · Analytics · Automation · More` (same 5).
- NOTE: current Flutter code hides Analytics from institute admins (`showAnalytics = !isInstituteAdmin` in `dashboard_screen.dart` and `dashboard_web.dart`). **Decision: institute admins DO get Analytics**, scoped to their institute. Change that line when implementing.

Top bar (all screens): white, title left, **bell with count badge** + **avatar** (avatar → More). Pushed screens have a back arrow.

Breakpoints that exist in code today:
- `900dp` (`DashboardPage.desktopBreakpoint`) → below = mobile, ≥ 900 = web layout. Also used by `/building` and `/device` routes in `main.dart`.
- `380dp` (`isCompact` in `dashboard_screen.dart`, Home tab only) → compact padding/hero text.

---

## 3. Visual system (final state)

### 3.1 Layout principle — "Option 1: white + flat"
- Screen background **#FFFFFF** (phone screen and content).
- Lists run **full width** with 1px dividers (`--line`), dividers inset to the text (start at 68px when a row has an icon, 16px otherwise).
- Cards removed except: **energy hero card**, **charts** (card with 1px border), map, forecast model columns.
- Former cards (schedules, settings, profile, power card) are flat sections separated by a bottom divider.
- KPI tiles: 2×2 grid split by hairlines (no boxes).
- Section spacing 28–36px; screen gutter 16px; tap targets ≥ 48dp.

### 3.2 "Outline system" (no tinted fills)
Themed color is used on **lines and glyphs, never as a fill**, except: the energy hero card, solid primary buttons (Save/Apply/Done), switches when on, selected schedule day circles, and status colors.
- Row icons: white box + 1px grey border + icon in theme color (**Outline icon style** — chosen over Tinted/Neutral/Plain).
- Bottom nav active tab: white pill with 1.5px theme ring; icon + label in theme color.
- Selected chips / active-filter chips: white, theme border + text.
- Segmented controls (Usage/Forecast, Floor 1/2, Line/Bar…): selected segment gets a theme ring.
- Avatar, member initials, "Institute admin · IC" badge: white with theme ring.
- Tonal buttons → outline buttons.
- Reading boxes, notes, tap-a-day readout, "Compare with…" prompt: white + 1px grey border.
- Best forecast model column: theme border.
- Unread notifications: no tint (dot marks unread).
- Power button halo: thin grey ring.
- Calendar range: underline instead of fill.

### 3.3 Text colors (readability pass — "avoid grayed text")
| Role | Hex | Contrast on white |
|---|---|---|
| Primary text `ink` | `#0E2E1A` | 14.7:1 |
| Secondary `ink-mid` (subtitles, row details, top-bar subtitles) | `#24402E` | 11.4:1 |
| Tertiary `ink-muted` (captions, timestamps, units) | `#3A5344` | 8.4:1 |
| Placeholder | `#51685A` | — |
| Disabled only | `#9AAEA1` | exempt |

- Small labels (KPI footers, units, notification times, forecast labels, reading labels) = **13px**.
- KPI labels, summary labels, section labels (Manage IC, Today, Next up) use full `ink`.
- Chart axis text `#3A5344`, weight 600.
- Paused schedules are not faded.

### 3.4 Type scale (mobile)
| Token | size / line | weight | Use |
|---|---|---|---|
| display | 36/40 | 700 | hero number |
| title-lg | 22/28 → **24/30 in top bar** | 700 | screen title |
| **Dashboard title** | **30/36** (date 15/20) | 700 | Home only |
| stat | 24/28 | 700 | KPI values |
| title | 18/24 | 600–700 | section titles |
| subtitle | 16/22 | 600 | list primary |
| body | 15/22 | 400 | messages |
| body-sm | 14/20 | 400 | secondary |
| label | 14/20 | 600 | buttons/chips |
| caption | 12–13 | 500 | floor = 12sp |
Numbers use tabular figures (`FontFeature.tabularFigures()`).

### 3.5 Campus (super admin) palette — unchanged brand green
`green-dark #1A5C35` (primary: buttons, active, switches) · `green-mid #2E9E52` (charts, success fills) · `green-light #6ECB8A` · `green-pale #C2EDD0` · wash `#E6F5EB` · line `#DCEBE1`.

Status (never themed): success `#2E9E52` / text `#1F7A40` · warning fill `#E8922A` / text `#A15208` / bg `#FDF1E2` · error fill `#D64A4A` / text `#B42318` / bg `#FDECEA` · offline `#8A948D` (preview uses `#9E9E9E` on map like web).

### 3.6 Institute palettes — FINAL (rebuilt in OKLCH for equal perceived strength, on white)
Replaces the old hue-rotated ramps in `lib/theme/institute_colors.dart`. Adds a 5th shade (**50/wash**).

| Institute | 900 (hero dark) | 700 (buttons, switches, links, active outlines) | 500 (charts, top-bar line) | 200 (selected) | 50 (wash) | line |
|---|---|---|---|---|---|---|
| **IC** indigo-violet | `#342F64` | `#534A9C` | `#7F79D1` | `#DADBFC` | `#F4F4FF` | `#E6E5F5` |
| **ILEGG** berry/plum | `#5A203A` | `#8D325C` | `#C1628A` | `#F8D2DF` | `#FEF1F5` | `#F2E2E9` |
| **ITED** Honey gold | `#542C07` | `#8B5500` | `#B47D06` | `#F6E7BB` | `#FCF8E8` | `#F0E6CC` |
| **IAAS** ocean | `#003E5F` | `#006095` | `#0891C9` | `#C2E4F8` | `#ECF7FE` | `#DCEAF4` |
| ADMIN | original green ramp | | | | | |

Contrast: white on 900 = 11–12:1; white on 700 = 6.2–7.7:1; 500 on white ≥ 3.6:1 (chart marks).
- Hero = linear-gradient 135° 900 → 700. ITED hero week/month numbers `#FBE3A0`.
- ITED only: "Peak" bar is an **orange outline** (white fill, 2.5px orange stroke) so it doesn't blend with gold bars; legend swatch matches.
- Rejected ITED options kept for reference: Bronze (700 `#784F00`, charts `#B8860B`), Gold+charcoal (hero `#2B2620`, gold `#EDB417` buttons with `#2B2000` text, charcoal `#443B32`, charts `#BC8800`).
- Institute theme applies: hero, buttons, switches, charts, active tab, 3px line under top bar (500), selected states. Status colors stay green/orange/red. `InstituteTheme.resolve` logic unchanged.
- Map/label colors for buildings in campus views use the 700 shades: IC `#534A9C`, ILEGG `#8D325C`, ITED `#8B5500`, IAAS `#006095`, ADMIN `#1A5C35`.

### 3.7 Components
- Buttons 48dp: primary (solid theme 700), outline (white + border), danger (red `#B42318`, only inside delete dialogs), text.
- **Add = icon only**: 40×40 outlined box with `+` in theme color.
- **Delete = icon only, grey** (`ink-mid`), not red. (Red appears only once deleting is in progress.)
- Chips 40dp pill; pills 24dp; segmented control 40dp segments.
- Switch 52×32 (on = theme 700).
- Inputs 52dp, 12px radius.
- Bottom sheets: 24px top radius, grab handle, header with title + Clear/Reset, footer Cancel/Apply.

---

## 4. Screens — CAMPUS ADMIN phone (final state)

### 4.1 Home ("Dashboard")
- Top bar: **"Dashboard"** 30/36 bold, date below ("Thursday, Sep 24" — use real date in app). No greeting (removed because it truncated).
- **Energy hero card** (green gradient): "Energy today" + Live pill · **128.46 kWh** · "8% less than yesterday" · sparkline of today by hour (12 AM → Now) · 3 cells: This week 812 / This month 1,583 / Peak hour 2–3 PM.
- **KPI 2×2** (icon inline with label, value 24px, footer): Month cost ₱18,236 (▲6% vs August, red) · Online 21/24 (3 offline) · High load 1 (IC Building) · Unassigned 3 (Need a room).
- **Building load** (This month · "All ›" → Devices): rows with **building icon** (outlined box, icon colored per institute; Admin uses `account_balance`, others `apartment`) — **no building codes as badges**, name, "N devices", load bar (red/orange/green), kWh + HIGH/MID/LOW pill.
- **Last 7 days** bar chart (Today dark + value label on top, Peak orange, Earlier light) + legend.
- **History** (from web `HistoryTrendPanel`): latest 5 days, each row = "Sep 24 · Thu", "₱ 857.74", **kWh bold + trend pill** (Increasing ≥ +5% orange, Decreasing ≤ −5% green, Stable otherwise; oldest = Baseline). "Analytics ›" link.

### 4.2 Devices — List
- Title "Devices", sub "24 devices in 5 buildings".
- Segmented **List | Map**.
- Search input, filter chips (All 24 / Online 21 / Offline 3 / Unassigned 3).
- "Buildings · Sorted by usage today" + **icon-only Add** (+) on the right.
- Rows: building icon, name, "2 floors · 5/6 on", kWh today, **grey trash icon** (delete building). Tapping row opens Building. (Chevron removed to make room.)
- **Add/delete building live here, not inside the building.**

### 4.3 Devices — Map (see §8 for full spec)
- Segmented List | Map, mode toggle **Buildings | Devices** (= web Approximate | Precise), zoom +/−, legend, detail panel.

### 4.4 Building (IC Building)
- Top bar: back, "IC Building", sub "Institute of Computing"; title tinted institute color with 3px line.
- Row: Floor 1 | Floor 2 segmented + **icon-only Add room**.
- Summary boxes: Devices / On now / Today kWh.
- Each room: heading ("Room 204", "Computer lab · 1.6 kW now") + **grey trash** (delete room); device rows: icon, name, "● Online · 180 W", switch.
- No "Delete building" here anymore.

### 4.5 Device detail
- Top bar: back, "Aircon", "IC · Floor 2 · Room 204", **unlink icon (link_off) = Remove device** (opens delete flow).
- **Big round power button** (112px; tap toggles On/Off and watts), "On", Online pill, watts, "seen 12 s ago".
- Live readings (PZEM-004T · every 5 s): Power, Energy today, Voltage, Current, Power factor, Cost today.
- Last 7 days bars (avg 5.8 kWh).
- Schedule row (tap → editor).
- Device ID row with copy icon.

### 4.6 Analytics — Usage tab
Header: period title (e.g. "Last 30 days"), span + scope line, **Filters** button with count badge; active filters as removable chips (×) + "Clear all".
1. **Summary**: Total energy big number (40px) + delta vs comparison ("Turn on Compare to see the change" when off); rows: Cost (₱11.52 per kWh), Daily average (+delta), Devices online.
2. **Consumption trend**: title + Line/Bar toggle; chart 210px; compare series dashed; legend stacked with spans; **tap a day** → readout panel (date, value, previous, % change); "Compare with previous period or last year" prompt when off.
3. **By utility**: stacked split bar + rows (Air conditioning / Outlets / Lights: % and kWh).
4. **Top consuming**: segmented Institutes | Rooms | Devices; ranked rows with bar; tapping an institute opens **Breakdown sheet** (by utility bars in institute color, by room, top devices, "Filter analytics to X").
5. **History** (10 days, same rules as Home).
6. **Export to Excel** (outline button).

**Filters** (mirrors web `analytics_filter.dart` + `analytics_filter_bar.dart`):
- Filters button → hub sheet listing: Time range / Group by / Scope / Utility / Compare & more (each shows current value) → each opens its own sheet with Clear / Cancel / Apply (edits a draft; Apply commits).
- **Time range**: Today, Last 7 days, **Last 30 days (default)**, Last 90 days, This month, Last month, This year, Custom range (month calendar; tap start + end; future days disabled; shows "N days").
- **Group by**: Hourly (disabled "Needs hourly readings"), Daily (≤ 1 year), Weekly (≥ 14 days), Monthly (≥ 60 days); "Suggested" tag; auto-fixes invalid group (web `suggestedGroup`: ≤62 daily, ≤180 weekly, else monthly).
- **Scope**: building chips → Floor → Room → Device cascade.
- **Utility**: Lights / Outlets / AC multi-select (all = none selected).
- **More**: Day type (All/Weekdays/Weekends), Time of day (disabled, class hours 7 AM–6 PM note), Compare with (Off/Previous/Last year, shows both spans), Show values as (kWh / Cost ₱).
- Compare spans: previous = same length immediately before; last year = same dates −1 year.

### 4.7 Analytics — Forecast tab
- Header: "Next N days", "From Sep 24 · scope · based on history to Sep 23"; horizon follows range (≤10 days → 7, ≤45 → 30, else 90) — same as web.
- Headline: "Expected energy ★ ARIMA · best" + big kWh + "About ₱X on the bill at ₱11.52 per kWh".
- **Compare models**: segmented XGBoost | LSTM.
- **Chart shows forecast days only** (no past data): ARIMA solid + fill (theme color), compared model **dotted** (XGBoost `#2E669E`, LSTM `#A15208`); legend "ARIMA · Sep 24 – Oct 23", "XGBoost · same days".
- **Side by side** columns (ARIMA vs chosen): Energy, Est. bill, Error (MAPE), Trained; best highlighted (theme border). Errors used: ARIMA 8.4%, XGBoost 9.1%, LSTM 11.7%.
- Verdict sentence ("XGBoost expects 3.6% more energy than ARIMA (+₱741). Its error is 0.7 points higher, so ARIMA stays the better guess.").
- "How to read this" note (MAPE over last 14 days; horizon rule).
- When scoped to a building/utility: XGBoost/LSTM unavailable (web `remoteModelsApply: !scoped`) → note + ARIMA only.

### 4.8 Automation (reorganized)
- Top bar "Automation", "7 of 8 schedules active". **No floating button.**
1. **Coming up today** (Thu, Sep 24): next 3 actions chronologically — time (theme color), "in 2h 19m", "Turn off · Aircon", "IC · Room 204 — AC shutdown".
2. **All schedules** header + **icon-only Add** (+) on the right; segmented All / Active / Paused with live counts.
3. Grouped **by building** (campus) — group header uppercase + count, bold underline.
4. Schedule card: icon, name, device · room, switch (toggles active; counts update); **mini timeline** of windows (filled dot = Turn on, hollow = Turn off, time bold 78px column); footer: repeat text ("Weekdays", "Weekends", "Every day", "Mon, Wed, Fri") or calendar dates with calendar icon; "Next: Today, 5:00 PM · turns off" / "Paused".
Sample schedules: Holiday shutdown (IC Room 205, calendar Oct 1–3, off 12:00 AM), AC shutdown (IC 204, off 5 PM weekdays), Lab lights (IC 105, on 7/off 12/on 1/off 6 weekdays), Morning lights (ILEGG 102), Faculty AC (ILEGG 201, M/W/F), Weekend outlets (ITED 105, paused), Hallway lights (ITED 210, every day off 7 PM), Lab AC (IAAS 101), Office AC (ADMIN Registrar).

### 4.9 Schedule editor ("Edit schedule" / "New schedule")
- Top bar: back + **trash icon (delete schedule)** — the only delete (bottom delete button was removed). New schedule has no delete.
- Sections: **Name** · **Device** (row: building · room; new = "Choose a device — Building, floor, room, then device") · **Actions** (label + icon-only add; each row = On/Off segmented, time field, ×) · **When**: segmented **Repeat weekly | Specific date(s)** (mirrors web `_scheduleModeToggle`):
  - Repeat weekly: chips Every day / Weekdays / Weekends / Custom; **day circles only appear for Custom**; at least one day stays on.
  - Specific date(s): month calendar (‹ ›), tap one day (one-time) or two (range), past days disabled, footer "Sep 28 – Oct 2 · 5 days".
- **Summary** sentence ("Aircon in Room 204 turns off at 5:00 PM, weekdays. Philippine time." / "…every day from Sep 28 to Oct 2" / "…on Oct 1 only" / "…on Mon, Tue…").
- Footer: Cancel / Save.
- Data to save (match web): `scheduleMode: 'weekly' | 'calendar'`, `startDate`/`endDate` `YYYY-MM-DD` (equal for one day), `days` empty in calendar mode. Reuse `widgets/range_calendar.dart`.

### 4.10 Notifications
- Top bar: back, "Notifications", "3 unread", actions: **mark all read** (done_all) + **clear all** (delete_sweep → delete flow).
- Chips All / Alerts 2 / Rate / Updates; grouped Today / Yesterday; row = semantic icon (High usage orange, Device offline red, Rate updated, Update ready), title + unread dot, full message, time. Tap navigates (building/device/settings).

### 4.11 More
- Profile row (avatar, name, email, "Super admin" pill), Manage: Users, Settings, Notifications (3 unread); App: About (Version 2.3.1); Sign out.

### 4.12 Users (Manage users)
- Search, Members 7 / Others 2, rows (initials avatar outlined, name, email, role + institute pills, ⋮). ⋮ → actions sheet: Make admin, Change institute, Reset password, **Delete account** (neutral color, opens delete flow).

### 4.13 Settings
- Electricity rate (₱11.52 per kWh, Auto, "Davao Light · Sep 23", Set manually + Save rate), Rate history, Register device (ID input "DEV-2024-XXXX", 24 registered, Register), App update (Install), Account.

---

## 5. Screens — INSTITUTE ADMIN phone (final state)

Institute picker above phone: IC / ILEGG / ITED / IAAS (reloads app with that palette/data). Everything is scoped to one institute; theme per §3.6; 3px institute line under top bar.

- **Home "Dashboard"** (+date): hero "IC energy today" (31.16 kWh in sample), This week / This month / floors·rooms; KPIs: Month cost, Online x/y, Rooms, Schedules; **Room load** (this month, rows with meeting_room icon, floor · devices, bar, kWh; tap → Devices); Last 7 days bars; **History (institute only, 5 days, "Analytics ›")**.
- **Devices**: title = building name, "8 devices · 7 online"; **List | Map** toggle; floor segmented + icon-only Add room; summary boxes; rooms with grey trash; device rows with switches. No building add/delete. Map → zoomed institute map (§8).
- **Analytics**: same as campus but **locked** to the institute (`LOCK`): Scope sheet says "Showing IC Building only. Narrow down by floor, room or device."; Clear all returns to the institute, not campus; Top consuming = Rooms | Devices only (rooms show "Floor N · x% of IC"); History institute-only; Forecast = ARIMA only with note "XGBoost and LSTM are trained on campus totals only…".
- **Automation**: only that institute's schedules, grouped **by room**; sub "x of y schedules active".
- **Notifications**: institute-only; "2 unread · IC only"; clear all clears institute notifications.
- **More**: profile (e.g. Maria Cruz, "Institute admin · IC"), Manage IC: Members ("IC accounts only"), Settings, Notifications; About; Sign out.
- **Members**: only institute accounts, admin marked "(you)", note "You can only see and manage IC accounts."; actions sheet without "Change institute".
- **Settings**: electricity rate shown **read-only** ("Set by the campus admin") — *assumption*, based on admin-only DB write rules; confirm.
- Sample institute admins: IC Maria Cruz, ILEGG Jose Reyes, ITED Liza Santos, IAAS Mark Villanueva.

---

## 6. Features ported from web
| Web source | Mobile location |
|---|---|
| `web_overview_tab.dart` stat grid, Building Load, Recent Usage | Home |
| `history_trend_panel.dart` (History, trend vs previous day, ±5%) | Home (5 days) + Analytics (10 days) |
| `analytics_filter.dart` / `analytics_filter_bar.dart` | Analytics Filters hub + sheets + chips |
| `history_screen_web.dart` KPIs with compare, trend Line/Bar, utility split, Top consuming | Analytics Usage |
| `breakdown_panel.dart` | Breakdown bottom sheet |
| `web_forecast_cards.dart` (ARIMA + compare XGBoost/LSTM, Best = lowest MAPE 14 days) | Forecast tab |
| `automation_screen_web.dart` weekly vs calendar mode, `range_calendar.dart` | Schedule editor |
| `campus_map_screen_web.dart` (Approximate/Precise, levels, side panel) | Devices → Map |
| `manage_users_screen_web.dart`, `settings_screen_web.dart`, `notifications_screen_web.dart` | Users, Settings, Notifications |

---

## 7. Deletion system (applies to every delete)

### 7.1 Two-step dialog (two separate cards, one after another)
Centered modal card over a scrim, with a "1 — 2 · Step x of 2" indicator.
- **Card 1 — Confirm**: red outlined icon, title ("Delete building?"), item name, "This will:" impact list, **Cancel / Continue (red)**.
- **Card 2 — Reason**: "Why are you deleting it?", "Pick one. This is saved with the deletion record.", **radio list**, "Other" shows a real text input ("Tell us briefly why"); **Back / Delete (red, disabled until a reason is picked)**.

### 7.2 Reasons per type (5–7 each, always ends with Other)
- **Building (7)**: Building is no longer in use · Merged with another building · Added by mistake or a duplicate · Will be re-added with a new code or name · Devices moved to another building · Energy monitoring no longer needed · Other. Impact: 2 floors and 3 rooms; 8 devices unassigned; 3 schedules stop; history stays.
- **Room (6)**: Room was converted or closed · Merged with another room · Added by mistake or a duplicate · Devices moved to another room · Room is under renovation · Other.
- **Device (6)**: Device is broken or faulty · Replaced with a new device · Moved to another room · Registered by mistake · Utility no longer monitored · Other.
- **Account (7)**: Left the college · Moved to another institute or role · Duplicate account · Security concern · Requested by the account owner · Inactive for a long time · Other.
- **Schedule (6)**: No longer needed · Class or office hours changed · Device was removed or replaced · Duplicate of another schedule · Created by mistake or for testing · Other.
- **Notifications / clear all (6)**: Already reviewed them · The issues are resolved · Not relevant to me · Too many alerts · Cleaning up the list · Other.

### 7.3 Entry points (icons only, grey)
Building → trash on Devices list row (campus only) · Room → trash beside room heading (both) · Device → link_off icon in device top bar · Account → Users ⋮ → Delete account · Schedule → trash in editor top bar · Notifications → delete_sweep in top bar. Removing a single time window in the editor (×) is immediate (part of editing).

### 7.4 Delete animation (~2 s) + Undo
1. Page scrolls the card into view if needed.
2. A **red strip** (`#B42318`, white text + check icon, same width as the card) **slides out from under the card** (translateY −100% → 0, 260 ms).
3. Holds ~1 s, then **tucks back** under the card.
4. The card **slides left** (translateX −105%, fade, 280 ms), then its **height collapses** (220 ms) and content below moves up.
5. Multiple items (clear all notifications) stagger 60 ms each; ends with "No notifications" empty state.
6. After deleting a building/schedule/device the app first navigates back to the list, then animates.
7. Reduced-motion respected.
- **Floating Undo**: dark snackbar above the bottom nav with red trash icon + message + outlined **Undo**; red progress line shrinks over **5 seconds**, then fades. Undo cancels the animation (if running), restores the item (slides back in) and shows "Restored".
- Implementation note: defer the Firebase delete until the 5 s pass, or keep a copy to restore. Store reason + "Other" text with the deletion record.

---

## 8. Campus map (Devices → Map)

Based on web `campus_map_screen_web.dart` and the real image `campus_map.png` (354×496).

- **Campus admin**: whole map. Mode **Buildings** (Approximate): one translucent colored zone per building labeled IC/ILEGG/ITED/IAAS/ADMIN, colored by this month's level; tap → panel: name, "IC · 653.4 kWh this month", level pill, Floors, Rooms, Devices, Online now, **View building**. Mode **Devices** (Precise): dashed zone outlines + one dot per device (grid-spread inside the zone like web when no saved position), colored by today's kWh; tap → panel: device · room, ON/OFF pill, Status, Today's energy, Level, **View device**. Nothing selected → "Pick a building/device" + Buildings on map / Devices assigned / Online now.
- Zoom +/− (1×–3×), drag to pan when zoomed. Legend with web wording: Precise "Today's kWh per device: Low (<1) · Mid (1–2) · High (≥2) · Offline"; Approximate "This month's kWh".
- **Institute admin**: Devices → List | **Map** → map **cropped/zoomed to their building zone** (6% padding), only their device dots, same device panel.
- Zones used in preview (fractions x, y, w, h of the image, **estimated by eye**): IC `.41,.29,.20,.10` · ILEGG `.68,.37,.31,.30` · ITED `.84,.07,.16,.27` · IAAS `.66,.85,.33,.10` · ADMIN `.12,.77,.46,.10`. Real app must read `hotspots/{code}` (x/y/w/h) and device positions `hotspots/{code}/devices/{id}` from Firebase like web.
- Level colors: high `#D64A4A`, mid `#E8922A`, low green, offline `#9E9E9E`. Device thresholds = web (≥2 high, 1–2 mid, <1 low). **Building thresholds in preview are 400/200 kWh (scaled for sample data); web uses ≥100 high, 50–100 mid.** Use web values in Flutter.

---

## 9. Preview page tooling (not part of the app)
- Two phones side by side: **Campus admin** (left) and **Institute admin** (right, with IC/ILEGG/ITED/IAAS picker). On narrow browsers a "Campus admin | Institute admin" switch shows one phone.
- **Resizable**: drag bottom-right grip of each phone (min 296×536 screen). Size readout under each phone ("360 × 800 dp"). Sizes are the **screen in dp**; 8px bezel added around.
- **Screen presets (device presets, not breakpoints)**: Small 320×640 · **Realme 8i 360×800 (default)** · Large 412×915 · Tablet 600×960. "Fit to window" toggle (off = 1:1).
- Esc = back on the last-touched phone.
- Sample clock: Thu Sep 24, 2:41 PM. All numbers are **sample data** (Home fixed numbers vs Analytics generated data don't match — fine for prototype).

---

## 10. Open items / next steps (in order)

1. **(Was in progress when session ended)** Implement responsive **compact mode with 6 presets**: when the screen is small, scale everything down (spacing, type, icons). Discussed recommendations:
   - Move the compact breakpoint from **380 → 360** (so 360dp phones like the Realme 8i get the regular layout; only < 360 compact).
   - Add a **600dp** tablet breakpoint (limit content width ~600 centered or 2 columns).
   - Suggested ranges: < 360 compact · 360–599 standard · 600–899 large/tablet · ≥ 900 web.
   - Common real widths: 360 (budget Android — Realme, Samsung A, Oppo, Vivo), 375 (iPhone SE/mini), 384, 390–393 (iPhone 12–15), 411–412 (Pixel/Samsung), 414–440 (Plus/Pro Max).
   - The 6 presets were not yet defined — decide them (e.g. 320×640, 360×800, 375×667, 393×852, 412×915, 600×960) and wire a compact scale for < 360.
2. Build the **Add building** form sheet (code, name, floors — like web "Add building" dialog). Currently just a message.
3. Implement in Flutter:
   - New `institute_colors.dart` values + `wash` shade (§3.6).
   - Text colors (§3.3), type scale (§3.4), white/flat layout + outline system (§3.1–3.2).
   - Nav changes (§2) incl. Analytics for institute admins.
   - Screens §4–5, deletion system §7, map §8.
4. Decide: can institute admins edit the electricity rate? (preview says no).
5. Optional: Dashboard title size for other tabs (currently only Home is 30px; others 24px).
6. Optional: update the Design-System artifact to match the final preview.

---

## 11. Decisions log (chronological, condensed)
1. Redesign for readability; new IA with 5 tabs; web screens ported.
2. Preview became a single tap-through phone (not a gallery).
3. Text trimmed, then partially restored ("remove unnecessary, not everything").
4. White background, Option 1 (flat, no cards).
5. Design pass: white top bar, hero sparkline, round power button, time-first schedules, unread tint (later removed).
6. Full Analytics parity (filters, compare, forecast compare), then reorganized for breathing room.
7. Automation day circles fixed (were squeezed) → later full reorganization.
8. History panel added (Home + Analytics).
9. Second phone: institute app side by side.
10. Institute palettes rebuilt (OKLCH); ITED = Honey gold.
11. Icon style = Outline; then outline system for all themed fills.
12. Darker secondary text.
13. Analytics for institute admins (locked scope).
14. Building icons instead of codes (campus).
15. Forecast chart shows only forecast days.
16. Home title "Dashboard" + date; enlarged to 30px.
17. Two-step delete (confirm → reason) everywhere; schedule delete only in top bar.
18. Repeat presets vs custom day circles; "When" = Repeat weekly | Specific date(s) with calendar.
19. Add = icon only; delete icons grey; Add schedule/building are static header buttons (no FAB).
20. Real campus map with zones/dots; institute zoomed map.
21. Add/delete building moved to Devices list.
22. Delete animation (red strip from under card, slide left) + 5 s floating Undo.
23. Resizable preview + device presets.
