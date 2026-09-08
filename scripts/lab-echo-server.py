#!/usr/bin/env python3
# =============================================================================
# Prisma AIRS on Kong AI Gateway - lab echo server
#
#   ./scripts/lab-echo-server.py [--port 8099] [--log payloads.jsonl]
#
# Stands in for the Prisma AIRS scan endpoint. It logs the exact payload the
# ai-custom-guardrail policy emits, then answers with a Prisma AIRS shaped
# verdict so the request under test proceeds.
#
# It exists to answer one question: what does $(content) actually contain?
# The probe in scripts/lab-tool-call-probe.sh plants AIRSPROBE_* markers in the
# system message, the user message, a tool definition, a tool call argument and
# a tool result. This server reports which of them survived into the payload.
#
# Standard library only. Runs anywhere Python 3 runs, no dependency to install.
#
# LAB ONLY. While the policy points here, Prisma AIRS is not scanning anything.
# Never run this against a gateway carrying production traffic, and set
# params.api_key to a dummy value first so no real token is sent here.
#
# Protocol, and how to read the output: docs/lab-tool-calls.md
# =============================================================================

import argparse
import json
import re
import sys
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# Planted by the probe. Any AIRSPROBE_* token is discovered, so a marker added
# to the probe shows up here with no change to this file. The expected set is
# named as well, because a position that is not scanned leaves no trace at all:
# without it, absence would be silent and unreadable.
MARKER = re.compile(r"AIRSPROBE_[A-Z_]+")

EXPECTED = [
    ("AIRSPROBE_SYSTEM", "system message"),
    ("AIRSPROBE_USER", "user message"),
    ("AIRSPROBE_TOOLDEF", "tools[].function.description"),
    ("AIRSPROBE_TOOLARGS", "assistant tool_calls[].function.arguments"),
    ("AIRSPROBE_TOOLRESULT", "role: tool result message"),
]

# Headers that must never reach a log file, even in a lab.
REDACTED = {"x-pan-token", "authorization", "cookie", "proxy-authorization"}

VERDICTS = {
    # action allow, category benign: the request proceeds.
    "allow": {"action": "allow", "category": "benign"},
    # action block: exercises the blocking branch of airs_verdict.
    "block": {
        "action": "block",
        "category": "malicious",
        "prompt_detected": {"injection": True},
        "response_detected": {"dlp": True},
    },
    # AIRS reports its own degradation through category, alongside action allow.
    # This is the case the fail-closed branch exists for.
    "error": {"action": "allow", "category": "error"},
    "timeout": {"action": "allow", "category": "timeout"},
}


class Handler(BaseHTTPRequestHandler):
    verdict = "allow"
    log_path = None
    seen = 0

    def do_POST(self):  # noqa: N802 - name imposed by BaseHTTPRequestHandler
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length).decode("utf-8", "replace")

        Handler.seen += 1
        stamp = datetime.now(timezone.utc).isoformat(timespec="seconds")

        try:
            body = json.loads(raw)
            pretty = json.dumps(body, indent=2, ensure_ascii=False)
        except json.JSONDecodeError as exc:
            body, pretty = None, f"<not JSON: {exc}>\n{raw}"

        print("=" * 78)
        print(f"#{Handler.seen}  {stamp}  {self.command} {self.path}")
        print("-" * 78)
        for name, value in self.headers.items():
            shown = "<redacted>" if name.lower() in REDACTED else value
            print(f"  {name}: {shown}")
        print("-" * 78)
        print(pretty)
        self.report(body, raw)
        sys.stdout.flush()

        if Handler.log_path:
            with open(Handler.log_path, "a", encoding="utf-8") as handle:
                handle.write(json.dumps({"at": stamp, "body": body or raw}) + "\n")

        answer = {
            "scan_id": f"lab-scan-{Handler.seen:04d}",
            "report_id": f"lab-report-{Handler.seen:04d}",
            "tr_id": (body or {}).get("tr_id"),
            **VERDICTS[Handler.verdict],
        }
        payload = json.dumps(answer).encode("utf-8")

        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def report(self, body, raw):
        """Answer the question the run was started for."""
        print("-" * 78)

        contents = (body or {}).get("contents")
        if not isinstance(contents, list) or not contents:
            print("  contents: absent or not a list — the policy did not build one")
            return

        first = contents[0] if isinstance(contents[0], dict) else {}
        # The two policies differ only here: INPUT sends prompt, OUTPUT response.
        phase = "INPUT" if "prompt" in first else "OUTPUT" if "response" in first else "?"
        scanned = first.get("prompt") or first.get("response") or ""

        print(f"  phase: {phase}    contents[0] keys: {sorted(first)}")
        print(f"  scanned text: {len(scanned)} chars")

        found = set(MARKER.findall(scanned))
        anywhere = set(MARKER.findall(raw))

        print("  position                                    marker reached")
        for marker, position in EXPECTED:
            if marker in found:
                state = "SCANNED"
            elif marker in anywhere:
                # In the payload but outside the scanned string: emitted by some
                # other part of the config, still not seen by Prisma AIRS.
                state = "in payload, NOT scanned"
            else:
                state = "absent — NOT scanned"
            print(f"    {position:<42}{state}")

        extra = sorted(anywhere - {marker for marker, _ in EXPECTED})
        if extra:
            print(f"  unexpected markers: {', '.join(extra)}")

    def log_message(self, *_args):
        """Silence the default access log; the block above is the log."""


def main():
    parser = argparse.ArgumentParser(description="Lab echo server for ai-custom-guardrail")
    parser.add_argument("--port", type=int, default=8099)
    parser.add_argument("--host", default="0.0.0.0")  # noqa: S104 - reachable from the data plane
    parser.add_argument("--verdict", choices=sorted(VERDICTS), default="allow")
    parser.add_argument("--log", dest="log", default=None, help="append raw payloads as JSON lines")
    args = parser.parse_args()

    Handler.verdict = args.verdict
    Handler.log_path = args.log

    print(f"Listening on {args.host}:{args.port}, answering: {args.verdict}")
    print("Point config request.url at this address, with a dummy api_key.")
    print("LAB ONLY: Prisma AIRS is not scanning while the policy points here.\n")

    try:
        ThreadingHTTPServer((args.host, args.port), Handler).serve_forever()
    except KeyboardInterrupt:
        print(f"\nStopped after {Handler.seen} request(s).")


if __name__ == "__main__":
    main()
