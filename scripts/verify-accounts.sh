#!/bin/zsh
# Checks every stored account the way an agent would use it: the folder is
# selected through `quota-manager exec`, the provider CLI must see the expected
# login there, and the app must have read fresh quota for it. Read-only: it
# never logs in, logs out, or refreshes tokens itself.
set -euo pipefail

cli="${QUOTA_MANAGER_CLI:-quota-manager}"
command -v "$cli" >/dev/null || { echo "quota-manager is not on PATH; run ./scripts/install.sh"; exit 1; }

"$cli" list --json | CLI="$cli" python3 /dev/fd/3 3<<'PYTHON'
import json, os, subprocess, sys
from datetime import datetime, timezone

cli = os.environ["CLI"]
accounts = json.load(sys.stdin)
if not accounts:
    print("No accounts stored yet."); sys.exit(1)

failures = 0
now = datetime.now(timezone.utc)
for a in accounts:
    ref, email = a["reference"], a.get("email")
    problems = []

    if a["provider"] == "codex":
        r = subprocess.run([cli, "exec", ref, "--", "codex", "login", "status"], capture_output=True, text=True)
        if r.returncode != 0:
            problems.append("codex sees no login in the folder")
    else:
        r = subprocess.run([cli, "exec", ref, "--", "claude", "auth", "status", "--json"], capture_output=True, text=True)
        try:
            status = json.loads(r.stdout)
        except ValueError:
            status = {}
        if not status.get("loggedIn"):
            problems.append("claude sees no login in the folder (check the exact path)")
        elif email and status.get("email") != email:
            problems.append(f"claude is logged in as {status.get('email')}, expected {email}")
        if status.get("configDirectory") != a["home"]:
            problems.append("CLAUDE_CONFIG_DIR did not reach claude")

    updated = a.get("lastUpdated")
    if not updated:
        problems.append("the app has never read quota (sign in from the menu bar)")
    else:
        age = (now - datetime.fromisoformat(updated.replace("Z", "+00:00"))).total_seconds() / 60
        if age > 20:
            problems.append(f"quota is {age:.0f} min old; the session may be revoked")
    if a.get("availablePercent") is None:
        problems.append("no quota figures")

    if problems:
        failures += 1
        print(f"FAIL  {ref:<32} " + "; ".join(problems))
    else:
        print(f"ok    {ref:<32} {email}  week {a.get('weeklyRemainingPercent')}% left, usable {a['availablePercent']}%")

for provider in ("codex", "claude"):
    if any(a["provider"] == provider for a in accounts):
        r = subprocess.run([cli, "pick", provider], capture_output=True, text=True)
        print(f"pick  {provider:<32} " + (r.stdout.strip() or r.stderr.strip()))

sys.exit(1 if failures else 0)
PYTHON
