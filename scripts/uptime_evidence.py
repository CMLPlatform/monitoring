#!/usr/bin/env python3
# /// script
# requires-python = ">=3.15"
# ///
"""Retain independent HTTP probe observations and complete UTC daily reports."""

import argparse
import http.client
import io
import json
import os
import re
import signal
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from datetime import UTC, date, datetime, timedelta
from pathlib import Path

SLOT_SECONDS = 300
SLOTS_PER_DAY = 86400 // SLOT_SECONDS
TIMEOUT_SECONDS = 10


class EvidenceError(ValueError):
    """Stored evidence is invalid or conflicts with a new observation."""


def utc_now():
    return datetime.now(UTC)


def parse_date(value):
    try:
        result = date.fromisoformat(value)
        if result.isoformat() != value:
            raise ValueError
        return result
    except ValueError:
        raise argparse.ArgumentTypeError("use YYYY-MM-DD") from None


def read_json(path):
    return json.loads(path.read_text(encoding="utf-8"))


def write_once(path, record):
    """Publish a complete file without replacing any existing evidence."""
    data = (
        json.dumps(record, sort_keys=True, indent=2, allow_nan=False) + "\n"
    ).encode()
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(dir=path.parent, prefix=".pending-")
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        try:
            os.link(temporary, path)
        except FileExistsError:
            if path.read_bytes() != data:
                raise EvidenceError(
                    "conflicting evidence; existing file retained"
                ) from None
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        os.unlink(temporary)


def validate_targets(targets):
    if not isinstance(targets, list) or not targets:
        raise ValueError("targets must be a nonempty JSON array")
    identifiers = set()
    for target in targets:
        if not isinstance(target, dict) or set(target) != {
            "id",
            "url",
            "project",
            "env",
        }:
            raise ValueError("each target needs exactly id, url, project and env")
        for field in ("id", "project", "env"):
            if not isinstance(target[field], str) or not re.fullmatch(
                r"[a-z0-9][a-z0-9_-]{0,63}", target[field]
            ):
                raise ValueError(
                    f"target {field} must use 1–64 lowercase letters, digits, _ or -"
                )
        if target["id"] in identifiers:
            raise ValueError("target ids must be unique")
        identifiers.add(target["id"])
        url = target["url"]
        if not isinstance(url, str) or any(
            not char.isprintable() or char.isspace() for char in url
        ):
            raise ValueError(
                "target URL must contain no whitespace or control characters"
            )
        parsed = urllib.parse.urlsplit(url)
        if (
            parsed.scheme not in ("http", "https")
            or not parsed.hostname
            or parsed.username is not None
            or parsed.password is not None
            or parsed.query
            or parsed.fragment
        ):
            raise ValueError(
                "target URL must be HTTP(S) without credentials, query or fragment"
            )
        if parsed.port is not None and not 1 <= parsed.port <= 65535:
            raise ValueError("target URL port must be between 1 and 65535")
    return targets


def inventory(store, day):
    choices = sorted((store / "inventories").glob("*.json"))
    eligible = [path for path in choices if parse_date(path.stem) <= day]
    if not eligible:
        raise ValueError(
            "no inventory covers this date; register before collecting evidence"
        )
    record = read_json(eligible[-1])
    if (
        record.get("schema_version") != 1
        or record.get("effective") != eligible[-1].stem
    ):
        raise EvidenceError("invalid inventory metadata")
    if not isinstance(record.get("vantage"), str) or not re.fullmatch(
        r"[a-z0-9][a-z0-9_-]{0,63}", record["vantage"]
    ):
        raise EvidenceError("invalid inventory vantage")
    validate_targets(record.get("targets"))
    return record


def register(store, targets, vantage, effective, now):
    if effective < now.date():
        raise ValueError("inventory cannot be registered retrospectively")
    if not re.fullmatch(r"[a-z0-9][a-z0-9_-]{0,63}", vantage):
        raise ValueError("vantage must use 1–64 lowercase letters, digits, _ or -")
    targets = validate_targets(targets)
    previous = sorted((store / "inventories").glob("*.json"))
    destination = store / "inventories" / f"{effective}.json"
    if previous and effective == now.date() and not destination.exists():
        raise ValueError("inventory changes must start on a future UTC date")
    if previous and read_json(previous[0])["vantage"] != vantage:
        raise ValueError("one evidence directory must keep a single vantage")
    record = {
        "schema_version": 1,
        "effective": str(effective),
        "vantage": vantage,
        "targets": targets,
    }
    write_once(store / "inventories" / f"{effective}.json", record)
    return record


class NoRedirect(urllib.request.HTTPRedirectHandler):
    # Follow-up requests could leave the configured target or collect a login page.
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def request_status(url):
    def deadline(_signum, _frame):
        raise TimeoutError

    previous = signal.signal(signal.SIGALRM, deadline)
    signal.setitimer(signal.ITIMER_REAL, TIMEOUT_SECONDS)
    try:
        opener = urllib.request.build_opener(
            urllib.request.ProxyHandler({}), NoRedirect()
        )
        request = urllib.request.Request(
            url, headers={"User-Agent": "uptime-evidence/1"}
        )
        try:
            with opener.open(request, timeout=TIMEOUT_SECONDS) as response:
                return response.status
        except urllib.error.HTTPError as error:
            status = error.code
            error.close()
            return status
        except (OSError, urllib.error.URLError, http.client.HTTPException, ValueError):
            return None
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous)


def observation_path(store, day, target, slot):
    return store / "observations" / str(day) / target / f"{slot:03d}.json"


def probe(store):
    now = utc_now()
    manifest = inventory(store, now.date())
    results = []
    for target in manifest["targets"]:
        started = utc_now()
        if started.date() != now.date():
            raise ValueError(
                "UTC day changed during probe; rerun with the current inventory"
            )
        slot = (
            started.hour * 3600 + started.minute * 60 + started.second
        ) // SLOT_SECONDS
        path = observation_path(store, started.date(), target["id"], slot)
        if path.exists():
            record = read_json(path)
            validate_observation(
                record, target, started.date(), slot, manifest["vantage"]
            )
        else:
            status = request_status(target["url"])
            record = {
                "schema_version": 1,
                "target": target,
                "vantage": manifest["vantage"],
                "started_at": started.isoformat(),
                "slot": slot,
                "status": status,
                "outcome": "success"
                if status is not None and 200 <= status < 300
                else "failure",
            }
            write_once(path, record)
        results.append(record)
    return {"schema_version": 1, "observations": results}


def validate_observation(record, target, day, slot, vantage):
    started = datetime.fromisoformat(record["started_at"])
    status = record.get("status")
    expected_outcome = (
        "success" if type(status) is int and 200 <= status < 300 else "failure"
    )
    if (
        record.get("schema_version") != 1
        or record.get("target") != target
        or record.get("vantage") != vantage
        or started.utcoffset() != timedelta(0)
        or started.date() != day
        or (started.hour * 3600 + started.minute * 60 + started.second) // SLOT_SECONDS
        != slot
        or record.get("slot") != slot
        or record.get("outcome") != expected_outcome
        or (
            status is not None and (type(status) is not int or not 100 <= status <= 599)
        )
    ):
        raise EvidenceError("invalid observation; evidence was not changed")
    return expected_outcome


def daily_report(store, day, now):
    if day >= now.date():
        raise ValueError("reports require a complete UTC day before today")
    manifest = inventory(store, day)
    targets = []
    for target in manifest["targets"]:
        counts = {"success": 0, "failure": 0, "unknown": 0}
        slots = []
        for slot in range(SLOTS_PER_DAY):
            path = observation_path(store, day, target["id"], slot)
            outcome = (
                validate_observation(
                    read_json(path), target, day, slot, manifest["vantage"]
                )
                if path.exists()
                else "unknown"
            )
            counts[outcome] += 1
            slots.append({"success": "S", "failure": "F", "unknown": "U"}[outcome])
        observed = counts["success"] + counts["failure"]
        targets.append(
            {
                **target,
                **counts,
                "slot_outcomes": "".join(slots),
                "expected_slots": SLOTS_PER_DAY,
                "coverage": observed / SLOTS_PER_DAY,
                "success_fraction_of_expected": counts["success"] / SLOTS_PER_DAY,
                "success_fraction_of_observed": counts["success"] / observed
                if observed
                else None,
            }
        )
    return {
        "schema_version": 1,
        "date": str(day),
        "window_start": f"{day}T00:00:00+00:00",
        "window_end": f"{day + timedelta(days=1)}T00:00:00+00:00",
        "slot_seconds": SLOT_SECONDS,
        "measurement": "first HTTP GET per slot; 2xx success; redirects are failures; no body read",
        "inventory_effective": manifest["effective"],
        "vantage": manifest["vantage"],
        "targets": targets,
    }


def validate_daily(record, day):
    if (
        record.get("schema_version") != 1
        or record.get("date") != str(day)
        or record.get("window_start") != f"{day}T00:00:00+00:00"
        or record.get("window_end") != f"{day + timedelta(days=1)}T00:00:00+00:00"
        or record.get("slot_seconds") != SLOT_SECONDS
        or not isinstance(record.get("vantage"), str)
        or not re.fullmatch(r"[a-z0-9][a-z0-9_-]{0,63}", record["vantage"])
        or parse_date(record["inventory_effective"]) > day
    ):
        raise EvidenceError("invalid daily report metadata")
    targets = record["targets"]
    validate_targets(
        [
            {key: item[key] for key in ("id", "url", "project", "env")}
            for item in targets
        ]
    )
    for item in targets:
        slots = item["slot_outcomes"]
        if (
            not isinstance(slots, str)
            or len(slots) != SLOTS_PER_DAY
            or set(slots) - set("SFU")
        ):
            raise EvidenceError("invalid daily report intervals")
        success, failure, unknown = (slots.count(char) for char in "SFU")
        observed = success + failure
        expected = {
            "success": success,
            "failure": failure,
            "unknown": unknown,
            "expected_slots": SLOTS_PER_DAY,
            "coverage": observed / SLOTS_PER_DAY,
            "success_fraction_of_expected": success / SLOTS_PER_DAY,
            "success_fraction_of_observed": success / observed if observed else None,
        }
        if any(item.get(key) != value for key, value in expected.items()):
            raise EvidenceError("daily report counts do not match intervals")


def main():
    parser = argparse.ArgumentParser(
        description="Retain independent probe evidence. stdout is JSON; no response bodies are retained.",
        epilog="Exit: 0 results, 1 probe failure, 2 invalid input, 3 cannot run, 130 interrupted.",
    )
    parser.add_argument("--version", action="version", version="uptime-evidence 1.0.0")
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("register", "probe", "summarize", "report"):
        command = commands.add_parser(name)
        command.add_argument(
            "--store", type=Path, required=True, help="off-hub evidence directory"
        )
        if name == "register":
            command.add_argument("--targets", type=Path, required=True)
            command.add_argument("--vantage", required=True)
            command.add_argument("--effective", type=parse_date, required=True)
        elif name == "summarize":
            command.add_argument("--date", type=parse_date, required=True)
        elif name == "report":
            command.add_argument("--start", type=parse_date, required=True)
            command.add_argument("--end", type=parse_date, required=True)
    args = parser.parse_args()
    try:
        now = utc_now()
        result: dict
        if args.command == "register":
            result = register(
                args.store, read_json(args.targets), args.vantage, args.effective, now
            )
        elif args.command == "probe":
            result = probe(args.store)
        elif args.command == "summarize":
            path = args.store / "daily" / f"{args.date}.json"
            result = (
                read_json(path)
                if path.exists()
                else daily_report(args.store, args.date, now)
            )
            validate_daily(result, args.date)
            write_once(path, result)
        else:
            if (
                args.end < args.start
                or args.end >= now.date()
                or (args.end - args.start).days > 366
            ):
                raise ValueError(
                    "report needs 1–367 complete UTC days in ascending order"
                )
            days = []
            day = args.start
            while day <= args.end:
                path = args.store / "daily" / f"{day}.json"
                record = (
                    read_json(path)
                    if path.exists()
                    else daily_report(args.store, day, now)
                )
                validate_daily(record, day)
                days.append(record)
                day += timedelta(days=1)
            result = {"schema_version": 1, "days": days}
        print(json.dumps(result, sort_keys=True, allow_nan=False))
        return (
            1
            if args.command == "probe"
            and any(item["outcome"] == "failure" for item in result["observations"])
            else 0
        )
    except EvidenceError:
        print(
            "error: invalid or conflicting stored evidence; existing files retained",
            file=sys.stderr,
        )
        return 3
    except ValueError as error:
        parser.error(str(error))
    except Exception:  # noqa: BLE001 - the CLI maps unexpected failures to exit 3
        print(
            "error: could not read, probe or write evidence; check files and permissions",
            file=sys.stderr,
        )
        return 3
    except KeyboardInterrupt:
        print("error: interrupted", file=sys.stderr)
        signal.signal(signal.SIGINT, signal.SIG_DFL)
        os.kill(os.getpid(), signal.SIGINT)


if __name__ == "__main__":
    for stream in (sys.stdout, sys.stderr):
        if isinstance(stream, io.TextIOWrapper):
            stream.reconfigure(encoding="utf-8", newline="\n")
    sys.exit(main())
