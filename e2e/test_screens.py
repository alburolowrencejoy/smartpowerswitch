"""Visits every screen for each account at desktop and phone width.

For each screen it scrolls to the bottom, stitches the views into one image
(e2e/screenshots/screens/<role>_<size>_<screen>.png), and flags page errors
and visible error messages. Read-only: it only navigates and scrolls.

Uses the same environment variables as test_dashboard.py.
"""
import re
import sys
from pathlib import Path

from PIL import Image
from playwright.sync_api import Page, sync_playwright

import test_dashboard as t

OUT = Path(__file__).parent / "screenshots" / "screens"
OUT.mkdir(parents=True, exist_ok=True)

WEB_SCREENS = ["Dashboard", "Devices", "Map", "Analytics", "Automation",
               "Manage Users", "Settings"]
PHONE_TABS = ["Home", "Devices", "Analytics", "Automation", "More"]
# Rows on the phone's More screen that open their own screen.
PHONE_MORE = ["Users", "Members", "Settings", "Notifications", "About"]

ERROR_TEXT = re.compile(
    r"cannot load|failed to load|something went wrong|permission denied|"
    r"exception|could not load|an error occurred", re.I)

failures: list[str] = []


def fail(msg: str) -> None:
    print("  FAIL", msg)
    failures.append(msg)


def find(page: Page, label: str, exact: bool = True):
    """Centre of the smallest semantics node labelled [label]."""
    return page.evaluate(
        """([label, exact]) => {
             const hits = [...document.querySelectorAll('flt-semantics')].filter(e => {
               const t = (e.getAttribute('aria-label') || e.innerText || '').trim();
               const first = t.split('\\n')[0].trim();
               return exact ? (t === label || first === label || t === label + ' ' + label)
                            : t.startsWith(label);
             }).map(e => [e, e.getBoundingClientRect()])
               .filter(([e, r]) => r.width > 0 && r.height > 0
                        && r.top >= 0 && r.top < innerHeight);
             if (!hits.length) return null;
             hits.sort((a, b) => a[1].width * a[1].height - b[1].width * b[1].height);
             const r = hits[0][1];
             return [r.x + r.width / 2, r.y + r.height / 2];
           }""", [label, exact])


def click(page: Page, label: str, exact: bool = True) -> bool:
    pos = find(page, label, exact)
    if not pos:
        return False
    page.mouse.click(*pos)
    page.wait_for_timeout(3500)
    t.semantics(page)
    return True


def capture(page: Page, name: str, x: int, max_views: int) -> list[str]:
    """Scroll through the screen, stitch the views, return all labels seen."""
    shots, seen, last = [], [], None
    h = page.viewport_size["height"]
    for i in range(max_views):
        path = OUT / f"_{name}_{i}.png"
        page.screenshot(path=str(path))
        shots.append(path)
        labels = [l for _, l in t.visible_texts(page)]
        seen += labels
        sig = "|".join(labels)
        if sig == last:
            shots.pop()
            path.unlink()
            break
        last = sig
        page.mouse.move(x, h // 2)
        page.mouse.wheel(0, int(h * 0.8))
        page.wait_for_timeout(700)
    images = [Image.open(p) for p in shots]
    if images:
        w = images[0].width
        sheet = Image.new("RGB", (w, sum(i.height for i in images)), "white")
        y = 0
        for im in images:
            sheet.paste(im, (0, y))
            y += im.height
        sheet.save(OUT / f"{name}.png")
    for im, p in zip(images, shots):
        im.close()
        p.unlink()
    return seen


def check_screen(page: Page, name: str, x: int, errors: list[str], phone: bool):
    before = len(errors)
    seen = capture(page, name, x, 8 if phone else 6)
    shown_errors = sorted({l for l in seen if ERROR_TEXT.search(l)})
    new_errors = errors[before:]
    status = "ok"
    if shown_errors:
        fail(f"{name}: error text on screen: {shown_errors[:3]}")
        status = "error text"
    if new_errors:
        fail(f"{name}: page errors: {new_errors[:3]}")
        status = "page error"
    if len(seen) < 5:
        fail(f"{name}: screen looks empty ({len(seen)} labels)")
        status = "empty"
    print(f"  {status:10} {name}  ({len(set(seen))} labels)")


def run_account(browser, role, email, password, size, w, h):
    phone = size == "phone"
    x = 195 if phone else 900
    ctx = browser.new_context(viewport={"width": w, "height": h})
    page = ctx.new_page()
    errors: list[str] = []
    page.on("pageerror", lambda e: errors.append(f"{e.name}: {e.message}"[:200]))
    page.on("console", lambda m: m.type == "error"
            and "GL Driver" not in m.text and errors.append(m.text[:200]))
    t.login(page, email, password)
    errors.clear()  # start-up noise before sign-in is reported separately
    print(f"\n== {role} @ {size}")

    if not phone:
        for screen in WEB_SCREENS:
            if not click(page, screen):
                print(f"  (not in menu) {screen}")
                continue
            check_screen(page, f"{role}_{size}_{screen.replace(' ', '')}",
                         x, errors, phone)
        # Notifications: the bell in the header (labelled with its count).
        if click(page, "Dashboard"):
            bell = page.evaluate("""() => { const e = [...document.querySelectorAll('flt-semantics')]
              .filter(e => /^\\d+$/.test((e.getAttribute('aria-label')||e.innerText||'').trim()))
              .map(e => e.getBoundingClientRect()).filter(r => r.top < 80 && r.width > 0)
              .sort((a, b) => b.x - a.x)[0]; return e ? [e.x + e.width/2, e.y + e.height/2] : null; }""")
            if bell:
                page.mouse.click(*bell)
                page.wait_for_timeout(3000)
                t.semantics(page)
                check_screen(page, f"{role}_{size}_Notifications", x, errors, phone)
    else:
        for tab in PHONE_TABS:
            if not click(page, f"{tab} {tab}") and not click(page, tab):
                print(f"  (no tab) {tab}")
                continue
            check_screen(page, f"{role}_{size}_{tab}", x, errors, phone)
        for item in PHONE_MORE:
            click(page, "More More") or click(page, "More")
            if not click(page, item, exact=False):
                continue
            check_screen(page, f"{role}_{size}_More-{item}", x, errors, phone)
            page.go_back()
            page.wait_for_timeout(2500)
            t.semantics(page)
    ctx.close()


def main() -> int:
    if any(not (e and p) for _, e, p in t.ACCOUNTS):
        print("Missing credentials (see test_dashboard.py)")
        return 2
    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        for role, email, password in t.ACCOUNTS:
            for size, w, h in t.SIZES:
                run_account(browser, role, email, password, size, w, h)
        browser.close()
    print(f"\n{len(failures)} failure(s)")
    for f in failures:
        print(" -", f)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
