import json
import unittest

from analyze_connection import analyze


def line(attempt, elapsed, event, **fields):
    return "11-11 18:30 I/ffi: RDALL_DIAG " + json.dumps(
        dict(attempt=attempt, elapsed_ms=elapsed, event=event, **fields)
    )


class AnalysisTests(unittest.TestCase):
    def test_interleaved_reconnects_and_out_of_order_decoder_records(self):
        result = analyze([
            line(1, 1000, "first_frame_submitted"),
            line(2, 0, "attempt_started"),
            line(1, 900, "first_video_received"),
            line(2, 500, "relay_fallback_started"),
            line(2, 600, "transport_ready", direct=False),
        ])
        first, second = result["attempts"]
        self.assertEqual(first["first_video_ms"], 900)
        self.assertEqual(first["first_submission_ms"], 1000)
        self.assertEqual(first["evidence"], [])
        self.assertEqual(second["evidence"], ["relay_fallback_observed", "relayed_connection"])

    def test_slow_decoder_queue_overflow_and_missing_submission(self):
        result = analyze([
            line(1, 100, "first_video_received"),
            line(1, 5000, "sample", decoded_frames=2, decode_mean_ms=50,
                 queue_overflows=3, decode_errors=1),
        ])
        evidence = result["attempts"][0]["evidence"]
        self.assertIn("client_video_queue_overflow", evidence)
        self.assertIn("decoder_errors", evidence)
        self.assertIn("decode_work_exceeds_30fps_frame_budget", evidence)
        self.assertIn("video_received_without_frame_submission", evidence)

    def test_idle_desktop_is_not_mislabeled_as_network_failure(self):
        result = analyze([line(1, 5000, "sample", decoded_frames=0,
                               decode_mean_ms=0, last_video_age_ms=4900)])
        self.assertEqual(result["attempts"][0]["evidence"], [])

    def test_invalid_and_non_diagnostic_records_are_not_echoed(self):
        result = analyze([
            "unrelated upstream log with private content",
            "RDALL_DIAG broken", "RDALL_DIAG []", "RDALL_DIAG {}",
            line(1, -1, "bad"), line(1, 0, "attempt_started"),
        ])
        self.assertEqual(result["invalid_records"], 4)
        self.assertEqual(len(result["attempts"]), 1)
        self.assertNotIn("private content", json.dumps(result))


if __name__ == "__main__":
    unittest.main()
