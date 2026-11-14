#!/usr/bin/env bash
# Mail a monthly build's summary through Cloudflare Email Sending: the NOTIFY_CMD of
# ops/monthly-build.sh, which runs it for a failed, locked or skipped run with the summary on stdin
# (one JSON object: status, host, started, minutes, tag, commit, planet, build_id, log, log_tail).
# Installed as /usr/local/sbin/meshwish-osm-notify-email (ops/README.md).
#
#   meshwish-osm-notify-email < summary.json
#
# Settings, from the environment: the unit's EnvironmentFile, which only root reads (systemd hands
# them to the run); none of them is in this repository.
#   NOTIFY_EMAIL_TO         where it goes: one address or several, comma-separated
#   NOTIFY_EMAIL_FROM       who sends it: an address on a domain onboarded to Email Sending
#   CLOUDFLARE_ACCOUNT_ID   the account the domain is on
#   CLOUDFLARE_API_TOKEN    a token with the Email Sending permission on that account, nothing more
# The token goes in a request header from the process, never on a command line. A 429, a 502-504
# or no answer is tried again, twice (a second copy beats a lost alert); an answer of success is
# sent (said so when the answer does not list the address as delivered or queued); anything else
# is reported, and the exit status is 1 when a recipient did not get it. All of it within
# DEADLINE_S (100 s, the recipients together), inside the 120 s monthly-build.sh gives it.
set -euo pipefail

for v in NOTIFY_EMAIL_TO NOTIFY_EMAIL_FROM CLOUDFLARE_ACCOUNT_ID CLOUDFLARE_API_TOKEN; do
  [[ -n "${!v:-}" ]] || { echo "notify-email: $v is not set" >&2; exit 2; }
done

# The mail, in Python: the program on the command line (no secret in it), the summary on stdin,
# the settings from the environment.
IFS= read -r -d '' PROGRAM <<'PY' || true
import json
import os
import sys
import time
import urllib.error
import urllib.request

summary = json.load(sys.stdin)
status = summary.get("status", "?")
host = summary.get("host", "?")
subject = f"[meshwish OSM layer] monthly build {status} on {host}"
lines = [
    f"The monthly build of the OSM layer on {host}: {status}.",
    "",
    f"started   {summary.get('started', '?')} ({summary.get('minutes', '?')} min)",
    f"tag       {summary.get('tag') or '-'} {(summary.get('commit') or '')[:12]}",
    f"planet    {summary.get('planet') or '-'}",
    f"build     {summary.get('build_id') or '-'}",
    f"log       {summary.get('log') or '-'}",
]
if status == "skipped":
    lines += ["", "Nothing to build: the newest planet is the one the current build has."]
lines += ["", "The log's last lines:", "", summary.get("log_tail") or "(none)"]
text = "\n".join(lines)

account = os.environ["CLOUDFLARE_ACCOUNT_ID"]
url = f"https://api.cloudflare.com/client/v4/accounts/{account}/email/sending/send"
token = os.environ["CLOUDFLARE_API_TOKEN"]
sender = os.environ["NOTIFY_EMAIL_FROM"]
failed = 0
DEADLINE_S = 100
deadline = time.monotonic() + DEADLINE_S


def send(to):
    """Mail ``to``: (sent, what happened)."""
    payload = {"to": to, "from": {"address": sender, "name": "meshwish OSM layer"}, "subject": subject, "text": text}
    for attempt in range(3):
        left = deadline - time.monotonic()
        if left < 5:
            return False, f"not tried: past the {DEADLINE_S} s the notification has"
        request = urllib.request.Request(
            url,
            data=json.dumps(payload).encode(),
            headers={
                "Authorization": f"Bearer {token}",
                "Content-Type": "application/json",
                "User-Agent": "meshwish-osm-layer-notify",
            },
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=min(30.0, left)) as response:
                code, raw = response.status, response.read()
        except urllib.error.HTTPError as error:
            code, raw = error.code, error.read()
        except OSError as error:
            code, raw = None, str(error).encode()
        wait = 10 * (attempt + 1)
        if (code is None or code in (429, 502, 503, 504)) and attempt < 2 and deadline - time.monotonic() > wait + 5:
            time.sleep(wait)
            continue
        break
    try:
        body = json.loads(raw)
    except ValueError:
        body = None
    body = body if isinstance(body, dict) else {}
    result = body.get("result") if isinstance(body.get("result"), dict) else {}
    if code == 200 and body.get("success"):
        for outcome in ("delivered", "queued"):
            found = result.get(outcome)
            if isinstance(found, list) and to.lower() in (str(a).lower() for a in found):
                return True, outcome
        return True, f"accepted, the answer not listing the address ({json.dumps(result)[:200]})"
    errors = body.get("errors") if isinstance(body.get("errors"), list) else []
    said = "; ".join(str(e.get("message", e)) if isinstance(e, dict) else str(e) for e in errors)
    return False, f"HTTP {code}: {said or raw[:200].decode(errors='replace')}"


recipients = [a.strip() for a in os.environ["NOTIFY_EMAIL_TO"].split(",") if a.strip()]
if not recipients:
    print("notify-email: NOTIFY_EMAIL_TO names no address", file=sys.stderr)
    sys.exit(2)
for to in recipients:
    try:
        sent, what = send(to)
    except Exception as error:  # one recipient's trouble does not keep the mail from the others
        sent, what = False, repr(error)
    if sent:
        print(f"notify-email: {what} to {to}")
    else:
        failed += 1
        print(f"notify-email: not sent to {to} ({what})", file=sys.stderr)
sys.exit(1 if failed else 0)
PY
exec python3 -I -c "$PROGRAM"
