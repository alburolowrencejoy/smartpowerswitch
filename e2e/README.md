# Browser tests (Playwright)

`test_dashboard.py` signs in as a campus admin and an institute admin, at
desktop (1440×900) and phone (390×844) width, and checks the dashboard's
Davao Light card: it is shown, sits above History, has urgency labels, has
no "See all" link, and shows no Apply button to institute admins. It is
read-only (never presses Apply or Dismiss) and saves screenshots to
`e2e/screenshots/`.

It runs against the live Firebase project, so use real accounts.

## One-time setup (PowerShell, from the project root)

```powershell
py -m venv e2e\.venv
e2e\.venv\Scripts\python.exe -m pip install -r e2e\requirements.txt
$env:PLAYWRIGHT_BROWSERS_PATH = "$PWD\e2e\.browsers"
e2e\.venv\Scripts\python.exe -m playwright install chromium
```

`.venv`, `.browsers` and `screenshots` are git-ignored.

## Run

```powershell
flutter build web
# In a second terminal: serve the build
e2e\.venv\Scripts\python.exe -m http.server 8099 --bind 127.0.0.1 --directory build\web

# In the first terminal:
$env:PLAYWRIGHT_BROWSERS_PATH = "$PWD\e2e\.browsers"
$env:SPS_URL = 'http://127.0.0.1:8099/'
$env:SPS_ADMIN_EMAIL = '...'; $env:SPS_ADMIN_PASS = '...'
$env:SPS_INST_EMAIL  = '...'; $env:SPS_INST_PASS  = '...'
$env:PYTHONIOENCODING = 'utf-8'
e2e\.venv\Scripts\python.exe e2e\test_dashboard.py
```

Never commit the passwords; set them only in your terminal.

### Every screen

`test_screens.py` (same variables, run from inside `e2e\`) opens every
screen in the side menu (web) or bottom bar and More menu (phone), scrolls
to the bottom, and saves one stitched image per screen to
`e2e/screenshots/screens/`. It fails on page errors, visible error
messages, or an empty screen. Look through the images too: it can't judge
whether numbers are right or a layout looks broken.

```powershell
cd e2e
.venv\Scripts\python.exe test_screens.py
```

Known gap: on desktop it can't open the notification bell yet, so the
"Notifications" image shows the dashboard instead.

Exit code 0 means every check passed. Errors and warnings from the page are
reported with the step they happened in (`login page` or `dashboard`).
