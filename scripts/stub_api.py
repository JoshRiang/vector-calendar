#!/usr/bin/env python3
"""Stub API server for screenshot CI — stdlib only.

Serves on :9473 with realistic, fully-populated calendar data matching every
field the Flutter app renders (title, scheduled_at, all_day, minutes, location,
notes, priority, status, id, goal_id).
"""

from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs
import json

# ── Data ──────────────────────────────────────────────────────────────────────
# Build a realistic November 2026 week centred on 7 Nov (Saturday) so the
# screenshot CI always shows the same content regardless of when it runs.

TODAY_STR = "2026-11-07"

# All items for the month of November 2026.
ITEMS = [
    # Monday 2 Nov
    {"id": "evt_001", "title": "Sprint planning",
     "scheduled_at": "2026-11-02T09:00:00", "all_day": 0, "minutes": 60,
     "location": "Zoom", "notes": "", "priority": 1, "status": "todo",
     "goal_id": "goal_sprint"},
    {"id": "evt_002", "title": "Coffee with Sarah",
     "scheduled_at": "2026-11-02T12:30:00", "all_day": 0, "minutes": 30,
     "location": "Blue Bottle", "notes": "", "priority": 4, "status": "todo",
     "goal_id": ""},
    {"id": "evt_003", "title": "Deep work: algorithm refactor",
     "scheduled_at": "2026-11-02T14:00:00", "all_day": 0, "minutes": 120,
     "location": "Home office", "notes": "", "priority": 2, "status": "todo",
     "goal_id": "goal_algo"},

    # Tuesday 3 Nov
    {"id": "evt_004", "title": "Team standup",
     "scheduled_at": "2026-11-03T08:30:00", "all_day": 0, "minutes": 15,
     "location": "Slack Huddle", "notes": "", "priority": 3, "status": "todo",
     "goal_id": "goal_sprint"},
    {"id": "evt_005", "title": "1:1 with manager",
     "scheduled_at": "2026-11-03T10:00:00", "all_day": 0, "minutes": 30,
     "location": "Meeting room B", "notes": "", "priority": 2, "status": "todo",
     "goal_id": ""},
    {"id": "evt_006", "title": "Gym — upper body",
     "scheduled_at": "2026-11-03T17:30:00", "all_day": 0, "minutes": 60,
     "location": "Equinox Midtown", "notes": "", "priority": 3, "status": "todo",
     "goal_id": "goal_fitness"},

    # Wednesday 4 Nov
    {"id": "evt_007", "title": "Hackathon — Vector Suite",
     "scheduled_at": "2026-11-04T00:00:00", "all_day": 1, "minutes": 480,
     "location": "WeWork SoHo", "notes": "Bring laptop + charger",
     "priority": 1, "status": "todo", "goal_id": "goal_hack"},
    {"id": "evt_008", "title": "Dinner reservation",
     "scheduled_at": "2026-11-04T19:00:00", "all_day": 0, "minutes": 90,
     "location": "Le Bernardin", "notes": "", "priority": 4, "status": "todo",
     "goal_id": ""},

    # Thursday 5 Nov
    {"id": "evt_009", "title": "Design review: Liquid Glass UI",
     "scheduled_at": "2026-11-05T11:00:00", "all_day": 0, "minutes": 60,
     "location": "Figma", "notes": "Review backdrop blur implementation",
     "priority": 2, "status": "todo", "goal_id": "goal_ui"},
    {"id": "evt_010", "title": "Client demo prep",
     "scheduled_at": "2026-11-05T14:00:00", "all_day": 0, "minutes": 90,
     "location": "Conference room A", "notes": "", "priority": 1, "status": "todo",
     "goal_id": "goal_demo"},
    {"id": "evt_011", "title": "Yoga class",
     "scheduled_at": "2026-11-05T07:00:00", "all_day": 0, "minutes": 60,
     "location": "Pure Yoga", "notes": "", "priority": 3, "status": "todo",
     "goal_id": "goal_fitness"},

    # Friday 6 Nov
    {"id": "evt_012", "title": "Deployment day",
     "scheduled_at": "2026-11-06T00:00:00", "all_day": 1, "minutes": 480,
     "location": "Production", "notes": "Monitor for 24h",
     "priority": 1, "status": "todo", "goal_id": "goal_release"},
    {"id": "evt_013", "title": "Friday retro",
     "scheduled_at": "2026-11-06T15:00:00", "all_day": 0, "minutes": 45,
     "location": "Zoom", "notes": "", "priority": 3, "status": "todo",
     "goal_id": "goal_sprint"},

    # Saturday 7 Nov (TODAY for the stub)
    {"id": "evt_014", "title": "Morning run",
     "scheduled_at": "2026-11-07T06:30:00", "all_day": 0, "minutes": 45,
     "location": "Central Park", "notes": "", "priority": 3, "status": "todo",
     "goal_id": "goal_fitness"},
    {"id": "evt_015", "title": "Side project: portfolio site",
     "scheduled_at": "2026-11-07T10:00:00", "all_day": 0, "minutes": 180,
     "location": "Home", "notes": "", "priority": 2, "status": "todo",
     "goal_id": "goal_portfolio"},
    {"id": "evt_016", "title": "Read: Designing Data-Intensive Apps",
     "scheduled_at": "2026-11-07T14:00:00", "all_day": 0, "minutes": 60,
     "location": "", "notes": "Chapter 5", "priority": 4, "status": "todo",
     "goal_id": "goal_learning"},
    {"id": "evt_017", "title": "Grocery shopping",
     "scheduled_at": "2026-11-07T16:00:00", "all_day": 0, "minutes": 40,
     "location": "Whole Foods", "notes": "", "priority": 3, "status": "todo",
     "goal_id": ""},

    # Sunday 8 Nov
    {"id": "evt_018", "title": "Meal prep Sunday",
     "scheduled_at": "2026-11-08T00:00:00", "all_day": 1, "minutes": 240,
     "location": "Kitchen", "notes": "Chicken + rice + veggies",
     "priority": 3, "status": "todo", "goal_id": "goal_fitness"},
    {"id": "evt_019", "title": "Doctor appointment",
     "scheduled_at": "2026-11-08T11:00:00", "all_day": 0, "minutes": 60,
     "location": "NYU Langone", "notes": "Annual checkup",
     "priority": 1, "status": "todo", "goal_id": ""},

    # More of the month so grid dots look alive
    {"id": "evt_020", "title": "Product roadmap meeting",
     "scheduled_at": "2026-11-09T09:30:00", "all_day": 0, "minutes": 60,
     "location": "Zoom", "notes": "", "priority": 2, "status": "todo",
     "goal_id": "goal_sprint"},
    {"id": "evt_021", "title": "Workshop: Flutter web perf",
     "scheduled_at": "2026-11-10T00:00:00", "all_day": 1, "minutes": 480,
     "location": "Google Office", "notes": "", "priority": 2, "status": "todo",
     "goal_id": "goal_learning"},
    {"id": "evt_022", "title": "Birthday dinner — Mom",
     "scheduled_at": "2026-11-11T18:30:00", "all_day": 0, "minutes": 120,
     "location": "Carmine's", "notes": "Don't forget flowers!",
     "priority": 1, "status": "todo", "goal_id": ""},
    {"id": "evt_023", "title": "Quarterly review",
     "scheduled_at": "2026-11-13T10:00:00", "all_day": 0, "minutes": 60,
     "location": "Boardroom", "notes": "", "priority": 1, "status": "todo",
     "goal_id": "goal_career"},
    {"id": "evt_024", "title": "Hack night",
     "scheduled_at": "2026-11-12T19:00:00", "all_day": 0, "minutes": 180,
     "location": "Meetup NYC", "notes": "", "priority": 3, "status": "todo",
     "goal_id": "goal_hack"},
    {"id": "evt_025", "title": "Flight to SF",
     "scheduled_at": "2026-11-20T08:00:00", "all_day": 0, "minutes": 240,
     "location": "JFK → SFO", "notes": "", "priority": 1, "status": "todo",
     "goal_id": "goal_trip"},
    {"id": "evt_026", "title": "Conference: AOSP",
     "scheduled_at": "2026-11-21T00:00:00", "all_day": 1, "minutes": 480,
     "location": "Moscone Center", "notes": "", "priority": 2, "status": "todo",
     "goal_id": "goal_trip"},

    # Inbox item (no scheduled_at — shows in "Undated" section)
    {"id": "evt_099", "title": "Review PR #42 on vector-tasks",
     "scheduled_at": None, "all_day": 0, "minutes": 30,
     "location": "", "notes": "", "priority": 2, "status": "todo",
     "goal_id": "goal_sprint"},
]

# Build day counts for the whole month
DAY_COUNTS = {}
for item in ITEMS:
    sa = item.get("scheduled_at")
    if sa and isinstance(sa, str) and len(sa) >= 10:
        dk = sa[:10]
        DAY_COUNTS[dk] = DAY_COUNTS.get(dk, 0) + 1


def _range_payload(qs):
    """Return items for [start, end] and day-counts with nested items."""
    start = qs.get("start", [TODAY_STR])[0]
    end = qs.get("end", ["2026-11-30"])[0]

    filtered = [i for i in ITEMS
                if (i.get("scheduled_at") or "")[:10] >= start
                and (i.get("scheduled_at") or "")[:10] <= end]

    days = []
    for dk, cnt in DAY_COUNTS.items():
        if dk >= start and dk <= end and cnt > 0:
            day_items = [i for i in ITEMS if (i.get("scheduled_at") or "")[:10] == dk]
            days.append({"date": dk, "count": cnt, "items": day_items})

    return {"items": filtered, "days": days}


def _today_payload():
    today_items = [i for i in ITEMS
                   if (i.get("scheduled_at") or "")[:10] == TODAY_STR]
    return {
        "date": TODAY_STR,
        "items": today_items,
        "summary": {
            "total": len(today_items),
            "minutes_planned": sum(i.get("minutes", 0) for i in today_items),
            "completed": 0,
        }
    }


def _startable_payload():
    return [i for i in ITEMS if i["status"] == "todo"]


def _goals_payload():
    return [
        {"id": "goal_sprint", "title": "Sprint 24 — Vector Suite polish",
         "status": "active", "done": 0, "total": 5},
        {"id": "goal_fitness", "title": "Health & fitness Q4",
         "status": "active", "done": 1, "total": 4},
        {"id": "goal_hack", "title": "Hackathon projects",
         "status": "active", "done": 0, "total": 2},
        {"id": "goal_ui", "title": "Liquid Glass UI redesign",
         "status": "active", "done": 2, "total": 6},
        {"id": "goal_portfolio", "title": "Portfolio website v2",
         "status": "active", "done": 1, "total": 8},
        {"id": "goal_learning", "title": "Reading list 2026",
         "status": "active", "done": 3, "total": 10},
    ]


# ── Request counters (let the screenshot script confirm the app reached us) ──

STATS = {"calendar_range": 0}


# ── HTTP server ────────────────────────────────────────────────────────────────

class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass  # quiet in CI

    def _respond(self, code, obj):
        body = json.dumps(obj, default=str).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self):
        self._respond(204, {})

    def do_POST(self):
        self._respond(200, {})  # generic no-op for POST /diag, /tasks, etc.

    def do_PATCH(self):
        self._respond(200, {})

    def do_DELETE(self):
        self._respond(200, {})

    def do_GET(self):
        parsed = urlparse(self.path)
        qs = parse_qs(parsed.query)
        path = parsed.path.rstrip("/")

        if path == "/diag":
            self._respond(200, {})
        elif path == "/__stats":
            self._respond(200, {"stats": STATS})
        elif path == "/calendar/range":
            self._respond(200, _range_payload(qs))
        elif path == "/today":
            self._respond(200, _today_payload())
        elif path == "/tasks/startable":
            self._respond(200, _startable_payload())
        elif path == "/goals":
            self._respond(200, _goals_payload())
        elif path == "/commands":
            self._respond(200, [])
        else:
            self._respond(404, {"error": "unknown endpoint"})


def main():
    server = HTTPServer(("0.0.0.0", 9473), Handler)
    print(f"Stub API on :9473  (PID {__import__('os').getpid()})")
    server.serve_forever()


if __name__ == "__main__":
    main()
