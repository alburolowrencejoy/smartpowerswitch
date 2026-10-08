"""Checks the Davao Light card on the dashboard for each role and width.

Reads credentials from the environment (never hard-code them):
  SPS_ADMIN_EMAIL / SPS_ADMIN_PASS   campus admin
  SPS_INST_EMAIL  / SPS_INST_PASS    institute admin
  SPS_URL                            app URL (default http://localhost:8099/)

Read-only: it never presses Apply or Dismiss. Screenshots go to
e2e/screenshots/. See e2e/README.md for setup.
"""
import os
import sys
from pathlib import Path

from playwright.sync_api import Page, sync_playwright

URL = os.environ.get("SPS_URL", "http://localhost:8099/")
OUT = Path(__file__).parent / "screenshots"
OUT.mkdir(exist_ok=True)

ACCOUNTS = [
    ("admin", os.environ.get("SPS_ADMIN_EMAIL"), os.environ.get("SPS_ADMIN_PASS")),
    ("institute", os.environ.get("SPS_INST_EMAIL"), os.environ.get("SPS_INST_PASS")),
]
SIZES = [("desktop", 1440, 900), ("phone", 390, 844)]
LEVELS = ("Urgent", "Important", "Normal")

failures: list[str] = []


def check(ok: bool, msg: str) -> None:
    print(("  PASS " if ok else "  FAIL ") + msg)
    if not ok:
        failures.append(msg)


def semantics(page: Page) -> None:
    page.evaluate("document.querySelector('flt-semantics-placeholder')?.click()")
    page.wait_for_timeout(800)


def visible_texts(page: Page) -> list[tuple[float, str]]:
    """(top y, label) of every semantics node currently on screen."""
    return page.evaluate(
        """() => [...document.querySelectorAll('flt-semantics')]
             // Leaf nodes only: a container's label repeats all its children.
             .filter(e => !e.querySelector('flt-semantics'))
             .map(e => {
             const r = e.getBoundingClientRect();
             const t = (e.getAttribute('aria-label') || e.innerText || '').trim();
             return [r.top, r.height, t];
           }).filter(([top, h, t]) => t && h > 0 && top > -5 && top < innerHeight)
             .map(([top, h, t]) => [top, t])"""
    )


def scroll_to(page: Page, text: str, x: int, max_steps: int = 40) -> bool:
    """Wheel-scrolls the dashboard until a node whose label starts with
    [text] is on screen."""
    for _ in range(max_steps):
        if any(t.startswith(text) for _, t in visible_texts(page)):
            return True
        page.mouse.move(x, page.viewport_size["height"] // 2)
        page.mouse.wheel(0, 350)
        page.wait_for_timeout(350)
    return False


def login(page: Page, email: str, password: str) -> None:
    page.goto(URL)
    page.wait_for_load_state("networkidle")
    # The login form can take a while on a cold start; keep turning on the
    # accessibility tree until the email field appears.
    for _ in range(20):
        page.wait_for_timeout(1500)
        semantics(page)
        if page.locator("input").count() >= 2:
            break
    page.locator("input[aria-label='you@dnsc.edu.ph'], input[placeholder='you@dnsc.edu.ph']").first.fill(email)
    page.locator("input[aria-label='Password'], input[placeholder='Password']").first.fill(password)
    page.locator("flt-semantics[role='button']", has_text="Sign in").first.click()
    page.evaluate("window.__stage = 'signing in'")
    page.wait_for_timeout(9000)  # sign-in + first data load
    semantics(page)


def run(page: Page, role: str, size: str) -> None:
    phone = size == "phone"
    title = "Davao Light" if phone else "Davao Light Updates"
    x = 195 if phone else 900

    found = scroll_to(page, title, x)
    check(found, f"{role}/{size}: Davao Light card is on the dashboard")
    if not found:
        page.screenshot(path=str(OUT / f"{role}_{size}_nocard.png"))
        return
    # Bring the card's top near the top of the screen so all of it shows.
    title_y = min(y for y, t in visible_texts(page) if t.startswith(title))
    page.mouse.wheel(0, max(0, title_y - (150 if phone else 90)))
    page.wait_for_timeout(600)
    page.screenshot(path=str(OUT / f"{role}_{size}.png"))

    texts = visible_texts(page)
    labels = [t for _, t in texts]
    joined = " | ".join(labels)
    card_y = min(y for y, t in texts if t.startswith(title))

    check(not any("See all in Notifications" in t for t in labels),
          f"{role}/{size}: no 'See all in Notifications' link")
    levels = [t for t in labels if t in LEVELS
              or any(t == f"Priority: {lv}" for lv in LEVELS)]
    check(bool(levels), f"{role}/{size}: urgency labels shown ({', '.join(levels) or 'none'})")

    has_apply = any(t.startswith("Apply ₱") for t in labels)
    if role == "institute":
        check(not has_apply, f"{role}/{size}: no Apply button for institute admin")
    else:
        print(f"  INFO {role}/{size}: Apply button "
              f"{'shown (pending rate)' if has_apply else 'not shown (no pending rate)'}")

    # History must come after the card.
    history_above = [y for y, t in texts if t.startswith("History") and y < card_y]
    check(not history_above, f"{role}/{size}: card sits above History")
    print(f"  INFO visible: {joined[:300]}")


def main() -> int:
    missing = [n for n, e, p in ACCOUNTS if not (e and p)]
    if missing:
        print(f"Missing credentials for: {', '.join(missing)} (see docstring)")
        return 2
    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        for role, email, password in ACCOUNTS:
            for size, w, h in SIZES:
                print(f"\n== {role} @ {size} ({w}x{h})")
                ctx = browser.new_context(viewport={"width": w, "height": h})
                page = ctx.new_page()
                errors: list[str] = []
                stage = ["login page"]
                page.on("pageerror", lambda e: errors.append(
                    f"[{stage[0]}] {e.name}: {e.message} {e.stack or ''}"[:300]))
                # Headless Chrome's WebGL "GPU stall" notices are not app errors.
                page.on("console", lambda m: m.type in ("error", "warning")
                        and "GL Driver Message" not in m.text
                        and errors.append(f"[{stage[0]}] console {m.type}: {m.text}"[:300]))
                login(page, email, password)
                stage[0] = "dashboard"
                page.screenshot(path=str(OUT / f"{role}_{size}_top.png"))
                run(page, role, size)
                check(not errors, f"{role}/{size}: no page errors")
                for e in errors[:5]:
                    print("    ", e)
                ctx.close()
        browser.close()
    print(f"\n{len(failures)} failure(s)")
    for f in failures:
        print(" -", f)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
