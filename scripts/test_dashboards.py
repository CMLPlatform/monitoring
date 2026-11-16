"""Check incident links and render PromQL cases from the provisioned dashboards."""

import json
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
DASHBOARDS = {
    name: json.loads((ROOT / "dashboards" / f"{name}.json").read_text())
    for name in ("stack-health", "service-health", "logs")
}


def panel(dashboard, title):
    return next(p for p in DASHBOARDS[dashboard]["panels"] if p["title"] == title)


class IncidentContracts(unittest.TestCase):
    def test_navigation_preserves_time_and_selection(self):
        for name in ("service-health", "logs"):
            destination = "logs" if name == "service-health" else "service-health"
            link = next(
                link
                for link in DASHBOARDS[name]["links"]
                if f"/d/{destination}/" in link.get("url", "")
            )
            self.assertTrue(link["keepTime"])
            self.assertTrue(link["includeVars"])
        links = panel("stack-health", "Ingest by Project")["fieldConfig"]["defaults"][
            "links"
        ]
        for destination in ("service-health", "logs"):
            self.assertTrue(
                any(f"/d/{destination}/" in link.get("url", "") for link in links),
                f"missing Ingest by Project link to {destination}",
            )
        for link in links:
            self.assertIn("${__field.labels.project:percentencode}", link["url"])
            self.assertIn("${__field.labels.env:percentencode}", link["url"])
            self.assertIn("${__url_time_range}", link["url"])

    def test_unknown_values_and_staleness_remain_visible(self):
        for p in DASHBOARDS["service-health"]["panels"]:
            if p["type"] == "stat":
                self.assertEqual(p["fieldConfig"]["defaults"]["noValue"], "Unknown")
        self.assertIn(
            "timestamp(",
            panel("service-health", "Newest Metric Age")["targets"][0]["expr"],
        )
        self.assertTrue(
            panel("stack-health", "Active Alerts")["options"]["stateFilter"]["noData"]
        )

    def test_runbook_and_signal_styles(self):
        for dashboard in DASHBOARDS.values():
            self.assertTrue(
                any(
                    "RUNBOOK.md#incident-workflow" in x.get("url", "")
                    for x in dashboard["links"]
                )
            )
        export = panel("stack-health", "Collector Export Failures")
        self.assertIn("(solid)", export["targets"][0]["legendFormat"])
        self.assertIn("(dashed)", export["targets"][1]["legendFormat"])
        self.assertIn("(dotted)", export["targets"][2]["legendFormat"])


def render_promtool_cases():
    template = (ROOT / "tests" / "dashboard-rules.test.yml").read_text()
    for token, title in (
        ("ERROR_RATE", "Error Rate"),
        ("ERROR_TIMESERIES", "Error Rate over Time"),
        ("METRIC_AGE", "Newest Metric Age"),
    ):
        expr = panel("service-health", title)["targets"][0]["expr"]
        for variable, value in (
            ("${service:regex}", "api"),
            ("$project", "review"),
            ("$env", "test"),
            ("$service", "api"),
            ("$__rate_interval", "2m"),
        ):
            expr = expr.replace(variable, value)
        template = template.replace(f"expr: {token}", f"expr: {json.dumps(expr)}")
    return template


if __name__ == "__main__":
    result = unittest.main(exit=False).result
    if not result.wasSuccessful():
        sys.exit(1)
    sys.stdout.write(render_promtool_cases())
