import contextlib
import http.client
import importlib.util
import io
import json
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from datetime import UTC, date, datetime, timedelta
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest.mock import patch

SCRIPT_PATH = Path(__file__).parents[1] / "scripts/uptime_evidence.py"
SPEC = importlib.util.spec_from_file_location("uptime_evidence", SCRIPT_PATH)
assert SPEC is not None and SPEC.loader is not None and SPEC.origin is not None
evidence = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(evidence)
DAY = date(2026, 1, 1)
START = datetime(2026, 1, 1, tzinfo=UTC)
TARGET = {
    "id": "demo",
    "url": "https://example.test/health",
    "project": "demo",
    "env": "test",
}


class HTTPHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/slow":
            time.sleep(0.3)
        statuses = {"/redirect": 302, "/fail": 503, "/unsupported": 600}
        self.send_response(statuses.get(self.path, 204))
        if self.path == "/redirect":
            self.send_header("Location", "/")
        self.end_headers()

    def log_message(self, format, *args):
        pass


class EvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.store = Path(self.temp.name)
        evidence.register(self.store, [TARGET], "outside", DAY, START)

    def observe(self, slot=0, status=204):
        stamp = START + timedelta(seconds=slot * 300)
        record = {
            "schema_version": 1,
            "target": TARGET,
            "vantage": "outside",
            "started_at": stamp.isoformat(),
            "slot": slot,
            "status": status,
            "outcome": "success"
            if status is not None and 200 <= status < 300
            else "failure",
        }
        evidence.write_once(
            evidence.observation_path(self.store, DAY, "demo", slot), record
        )
        return record

    def test_missing_intervals_and_denominator(self):
        self.observe(0)
        self.observe(1, 503)
        report = evidence.daily_report(self.store, DAY, START + timedelta(days=1))
        item = report["targets"][0]
        self.assertEqual(
            (item["success"], item["failure"], item["unknown"]), (1, 1, 286)
        )
        self.assertEqual(item["slot_outcomes"], "SF" + "U" * 286)
        self.assertAlmostEqual(item["coverage"], 2 / 288, delta=1e-12)
        self.assertAlmostEqual(item["success_fraction_of_observed"], 0.5, delta=1e-12)
        self.assertAlmostEqual(
            item["success_fraction_of_expected"], 1 / 288, delta=1e-12
        )
        evidence.validate_daily(report, DAY)

    def test_wholly_missing_day_is_unknown(self):
        record = evidence.daily_report(
            self.store, DAY + timedelta(days=40), START + timedelta(days=41)
        )
        self.assertEqual(record["targets"][0]["unknown"], 288)
        self.assertIsNone(record["targets"][0]["success_fraction_of_observed"])

    def test_inventory_history_not_current_targets(self):
        newer = {**TARGET, "id": "replacement"}
        tomorrow = DAY + timedelta(days=1)
        evidence.register(self.store, [newer], "outside", tomorrow, START)
        old = evidence.daily_report(self.store, DAY, START + timedelta(days=200))
        new = evidence.daily_report(self.store, tomorrow, START + timedelta(days=200))
        self.assertEqual(old["targets"][0]["id"], "demo")
        self.assertEqual(new["targets"][0]["id"], "replacement")
        with self.assertRaises(ValueError):
            evidence.register(
                self.store, [newer], "outside", DAY, START + timedelta(days=2)
            )
        with self.assertRaises(ValueError):
            evidence.register(self.store, [newer], "elsewhere", tomorrow, START)

    def test_same_day_inventory_change_cannot_remove_failure(self):
        tomorrow = START + timedelta(days=1)
        replacement = {**TARGET, "id": "replacement"}
        with self.assertRaises(ValueError):
            evidence.register(
                self.store, [replacement], "outside", tomorrow.date(), tomorrow
            )

    def test_atomic_idempotence_and_conflict_retains_evidence(self):
        path = self.store / "safe.json"
        evidence.write_once(path, {"success": 1})
        evidence.write_once(path, {"success": 1})
        with self.assertRaises(ValueError):
            evidence.write_once(path, {"success": 0})
        self.assertEqual(evidence.read_json(path), {"success": 1})
        self.assertEqual(list(self.store.glob(".pending-*")), [])

    def test_concurrent_writers_never_replace_evidence(self):
        path = self.store / "concurrent.json"
        errors = []

        def write(value):
            try:
                evidence.write_once(path, value)
            except ValueError:
                errors.append(value)

        threads = [
            threading.Thread(target=write, args=({"value": value},)) for value in (0, 1)
        ]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()
        self.assertEqual(len(errors), 1)
        self.assertNotEqual(evidence.read_json(path), errors[0])

    def test_probe_rerun_does_not_repeat_or_hide_failure(self):
        with (
            patch.object(evidence, "utc_now", return_value=START),
            patch.object(evidence, "request_status", return_value=503) as request,
        ):
            first = evidence.probe(self.store)
            again = evidence.probe(self.store)
        self.assertEqual(request.call_count, 1)
        self.assertEqual(first, again)
        self.assertEqual(first["observations"][0]["outcome"], "failure")

    def test_actual_start_slot_and_utc_boundary(self):
        stamp = START + timedelta(hours=23, minutes=59, seconds=59)
        with (
            patch.object(evidence, "utc_now", return_value=stamp),
            patch.object(evidence, "request_status", return_value=None),
        ):
            result = evidence.probe(self.store)
        self.assertEqual(result["observations"][0]["slot"], 287)
        with self.assertRaises(ValueError):
            evidence.daily_report(self.store, DAY, stamp)
        with self.assertRaises(ValueError):
            evidence.daily_report(self.store, DAY + timedelta(days=1), stamp)

    def test_invalid_urls_fail_before_collection(self):
        for url in (
            "ftp://example.test",
            "https://user:pass@example.test",
            "https://example.test/?token=x",
            "https://example.test/#secret",
            "https://example.test/\nheader",
            "https://example.test:99999",
        ):
            with self.subTest(url=url), self.assertRaises(ValueError):
                evidence.validate_targets([{**TARGET, "url": url}])
        with self.assertRaises(ValueError):
            evidence.validate_targets([TARGET, TARGET])
        with self.assertRaises(ValueError):
            evidence.validate_targets([{**TARGET, "id": "../elsewhere"}])

    def test_corrupt_observation_and_report_rejected(self):
        record = self.observe()
        for mutation in (
            {"slot": 1},
            {"target": {**TARGET, "url": "https://elsewhere.test"}},
            {"started_at": "2026-01-02T00:00:00+00:00"},
            {"outcome": "failure"},
            {"status": True},
        ):
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                evidence.validate_observation(
                    {**record, **mutation}, TARGET, DAY, 0, "outside"
                )
        report = evidence.daily_report(self.store, DAY, START + timedelta(days=1))
        report["targets"][0]["success"] = 288
        with self.assertRaises(ValueError):
            evidence.validate_daily(report, DAY)

    def test_archive_reconstructs_after_raw_loss_and_hub_replacement(self):
        self.observe()
        report = evidence.daily_report(self.store, DAY, START + timedelta(days=1))
        evidence.write_once(self.store / "daily" / f"{DAY}.json", report)
        shutil.rmtree(self.store / "observations")
        shutil.rmtree(self.store / "inventories")
        with (
            patch.object(
                sys,
                "argv",
                [
                    "uptime",
                    "report",
                    "--store",
                    str(self.store),
                    "--start",
                    str(DAY),
                    "--end",
                    str(DAY),
                ],
            ),
            patch.object(evidence, "utc_now", return_value=START + timedelta(days=200)),
            contextlib.redirect_stdout(io.StringIO()) as output,
        ):
            self.assertEqual(evidence.main(), 0)
        self.assertEqual(json.loads(output.getvalue())["days"], [report])

    def test_http_status_redirect_and_total_deadline(self):
        server = ThreadingHTTPServer(("127.0.0.1", 0), HTTPHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        base = f"http://127.0.0.1:{server.server_port}"
        self.assertEqual(evidence.request_status(base), 204)
        self.assertEqual(evidence.request_status(base + "/fail"), 503)
        self.assertEqual(evidence.request_status(base + "/redirect"), 302)
        with patch.object(evidence, "TIMEOUT_SECONDS", 0.05):
            self.assertIsNone(evidence.request_status(base + "/slow"))

    def test_unsupported_http_status_remains_readable_failed_evidence(self):
        server = ThreadingHTTPServer(("127.0.0.1", 0), HTTPHandler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        tomorrow = START + timedelta(days=1)
        target = {
            **TARGET,
            "url": f"http://127.0.0.1:{server.server_port}/unsupported",
        }
        evidence.register(self.store, [target], "outside", tomorrow.date(), START)
        with patch.object(evidence, "utc_now", return_value=tomorrow):
            first = evidence.probe(self.store)
            again = evidence.probe(self.store)
        self.assertEqual(first, again)
        self.assertIsNone(first["observations"][0]["status"])
        self.assertEqual(first["observations"][0]["outcome"], "failure")
        report = evidence.daily_report(
            self.store, tomorrow.date(), tomorrow + timedelta(days=1)
        )
        item = report["targets"][0]
        self.assertEqual(
            (item["success"], item["failure"], item["unknown"]), (0, 1, 287)
        )
        evidence.validate_daily(report, tomorrow.date())

    def test_unsupported_normal_response_status_is_not_persistable(self):
        with patch.object(evidence.urllib.request, "build_opener") as opener:
            opener.return_value.open.return_value.__enter__.return_value.status = 600
            self.assertIsNone(evidence.request_status(TARGET["url"]))

    def test_malformed_http_is_failed_observation_and_collection_continues(self):
        class BrokenOpener:
            def open(self, *args, **kwargs):
                raise http.client.BadStatusLine("BROKEN UPSTREAM")

        with patch.object(
            evidence.urllib.request, "build_opener", return_value=BrokenOpener()
        ):
            self.assertIsNone(evidence.request_status(TARGET["url"]))
        tomorrow = START + timedelta(days=1)
        second = {**TARGET, "id": "second"}
        evidence.register(
            self.store, [TARGET, second], "outside", tomorrow.date(), START
        )
        with (
            patch.object(evidence, "utc_now", return_value=tomorrow),
            patch.object(
                evidence.urllib.request, "build_opener", return_value=BrokenOpener()
            ),
        ):
            result = evidence.probe(self.store)
        self.assertEqual(len(result["observations"]), 2)
        self.assertTrue(
            all(item["outcome"] == "failure" for item in result["observations"])
        )

    def test_probe_exit_status_reports_observed_failure(self):
        for outcome, expected in (("success", 0), ("failure", 1)):
            with (
                self.subTest(outcome=outcome),
                patch.object(
                    sys, "argv", ["uptime", "probe", "--store", str(self.store)]
                ),
                patch.object(
                    evidence,
                    "probe",
                    return_value={
                        "schema_version": 1,
                        "observations": [{"outcome": outcome}],
                    },
                ),
                contextlib.redirect_stdout(io.StringIO()) as output,
            ):
                self.assertEqual(evidence.main(), expected)
                self.assertEqual(
                    json.loads(output.getvalue())["observations"][0]["outcome"], outcome
                )

    def test_total_deadline_interrupts_blocking_dns_or_headers(self):
        class BlockingOpener:
            def open(self, *args, **kwargs):
                time.sleep(1)
                raise OSError

        started = time.monotonic()
        with (
            patch.object(evidence, "TIMEOUT_SECONDS", 0.03),
            patch.object(
                evidence.urllib.request, "build_opener", return_value=BlockingOpener()
            ),
        ):
            self.assertIsNone(evidence.request_status(TARGET["url"]))
        self.assertLess(time.monotonic() - started, 0.5)

    def test_archived_summary_rerun_survives_raw_pruning(self):
        self.observe()
        record = evidence.daily_report(self.store, DAY, START + timedelta(days=1))
        path = self.store / "daily" / f"{DAY}.json"
        evidence.write_once(path, record)
        shutil.rmtree(self.store / "observations")
        before = path.read_bytes()
        with (
            patch.object(
                sys,
                "argv",
                ["uptime", "summarize", "--store", str(self.store), "--date", str(DAY)],
            ),
            patch.object(evidence, "utc_now", return_value=START + timedelta(days=200)),
            contextlib.redirect_stdout(io.StringIO()) as output,
        ):
            self.assertEqual(evidence.main(), 0)
        self.assertEqual(json.loads(output.getvalue()), record)
        self.assertEqual(path.read_bytes(), before)

    def test_cli_conflicting_inventory_returns_runtime_error_without_replacing(self):
        original = self.store / "inventories" / f"{DAY}.json"
        before = original.read_bytes()
        targets = self.store / "targets.json"
        targets.write_text(
            json.dumps([{**TARGET, "url": "https://changed.example.test"}]),
            encoding="utf-8",
        )
        with (
            patch.object(
                sys,
                "argv",
                [
                    "uptime",
                    "register",
                    "--store",
                    str(self.store),
                    "--targets",
                    str(targets),
                    "--vantage",
                    "outside",
                    "--effective",
                    str(DAY),
                ],
            ),
            patch.object(evidence, "utc_now", return_value=START),
            contextlib.redirect_stdout(io.StringIO()) as output,
            contextlib.redirect_stderr(io.StringIO()),
        ):
            self.assertEqual(evidence.main(), 3)
        self.assertEqual(output.getvalue(), "")
        self.assertEqual(original.read_bytes(), before)

    def test_cli_help_usage_error_and_missing_file(self):
        command = [sys.executable, "-B", str(SCRIPT_PATH)]
        help_result = subprocess.run(
            [*command, "--help"], check=False, capture_output=True, text=True
        )
        self.assertEqual(help_result.returncode, 0)
        self.assertIn("Exit: 0 results", help_result.stdout)
        invalid = subprocess.run(
            [
                *command,
                "report",
                "--store",
                str(self.store),
                "--start",
                "bad",
                "--end",
                "2026-01-02",
            ],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(invalid.returncode, 2)
        self.assertEqual(invalid.stdout, "")
        missing = subprocess.run(
            [
                *command,
                "register",
                "--store",
                str(self.store),
                "--targets",
                str(self.store / "absent"),
                "--vantage",
                "outside",
                "--effective",
                str(datetime.now(UTC).date()),
            ],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(missing.returncode, 3)
        self.assertNotIn("Traceback", missing.stderr)


if __name__ == "__main__":
    unittest.main()
