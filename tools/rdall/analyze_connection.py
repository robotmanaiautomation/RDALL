#!/usr/bin/env python3
"""Extract only RDALL_DIAG JSON records from logcat or an exported log file."""
import argparse
import json
import sys
from collections import defaultdict

PREFIX = "RDALL_DIAG "


def analyze(lines):
    attempts = defaultdict(list)
    invalid = 0
    for line in lines:
        if PREFIX not in line:
            continue
        try:
            event = json.loads(line.split(PREFIX, 1)[1])
            if not isinstance(event, dict):
                raise ValueError("not an object")
            attempt = event.get("attempt")
            elapsed = event.get("elapsed_ms")
            if type(attempt) is not int or type(elapsed) is not int or elapsed < 0:
                raise ValueError("invalid timing record")
            if not isinstance(event.get("event"), str):
                raise ValueError("missing event")
        except (ValueError, TypeError):
            invalid += 1
            continue
        attempts[attempt].append(event)

    results = []
    for attempt, events in sorted(attempts.items()):
        # Decoder and IO threads can write adjacent records in the reverse order.
        events.sort(key=lambda e: e["elapsed_ms"])
        phases = [e for e in events if e["event"] == "phase"]
        samples = [e for e in events if e["event"] == "sample"]
        evidence = []
        if any(e["event"] in ("relay_fallback_started", "secure_handshake_relay_fallback") for e in events):
            evidence.append("relay_fallback_observed")
        if any(e["event"] == "transport_ready" and e.get("direct") is False for e in events):
            evidence.append("relayed_connection")
        if any(s.get("queue_overflows", 0) for s in samples):
            evidence.append("client_video_queue_overflow")
        if any(s.get("decode_errors", 0) for s in samples):
            evidence.append("decoder_errors")
        if any(s.get("decode_mean_ms", 0) > 33.33 and s.get("decoded_frames", 0) > 0 for s in samples):
            evidence.append("decode_work_exceeds_30fps_frame_budget")
        first_video = next((e["elapsed_ms"] for e in events if e["event"] == "first_video_received"), None)
        first_submit = next((e["elapsed_ms"] for e in events if e["event"] == "first_frame_submitted"), None)
        if first_video is not None and first_submit is None:
            evidence.append("video_received_without_frame_submission")
        results.append({
            "attempt": attempt,
            "first_video_ms": first_video,
            "first_submission_ms": first_submit,
            "phase_durations": [
                {"phase": e.get("from"), "duration_ms": e.get("phase_ms")}
                for e in phases
            ],
            "evidence": evidence,
            "events": events,
        })
    return {"attempts": results, "invalid_records": invalid}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", nargs="?", help="log file; stdin when omitted")
    args = parser.parse_args()
    if args.log:
        with open(args.log, encoding="utf-8", errors="replace") as source:
            result = analyze(source)
    else:
        result = analyze(sys.stdin)
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
