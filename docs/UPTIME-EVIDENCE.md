# Retain independent uptime evidence

Prometheus keeps at most 30 days of raw metrics. Use the independent probe to
retain daily JSON reports beyond that window. Run it on a second host outside
the monitoring hub's failure domain. The repository does not install a schedule
or choose a storage host.

## Prepare the second host

The commands below require Linux, `uv`, Python 3.15, GNU `timeout`,
a checkout at `/opt/monitoring`, and a writable evidence directory at
`/var/lib/monitoring-uptime`.
Provision Python 3.15 with the host's normal tooling before scheduling.
Run the manual commands first so cron never needs to provision the runtime.
Use a dedicated, unprivileged account. Keep this directory private and outside
the checkout. The probe needs outbound HTTP/S access, but no monitoring credentials.

1. Review `config/uptime-targets.json`. This is the independent probe's inventory;
   `just probe-add` only updates the hub's Blackbox inventory.
   Use final URLs: every redirect counts as failure. A probe accepts 2xx response
   headers without reading the body, ignores proxy environment variables, and
   enforces a ten-second deadline per target.
2. Register the inventory with today's UTC date:

   ```sh
   cd /opt/monitoring
   uv run --no-project --python 3.15 scripts/uptime_evidence.py register --store /var/lib/monitoring-uptime --targets config/uptime-targets.json --vantage second-host --effective "$(date -u +%F)"
   ```

3. Run one probe manually:

   ```sh
   uv run --no-project --python 3.15 scripts/uptime_evidence.py probe --store /var/lib/monitoring-uptime
   ```

4. Inspect the JSON output. Check that each target has an observation. Exit 1
   means a target failed, exit 2 means invalid input, and exit 3 means the command
   could not complete.

For inventory changes, register a new manifest effective on a future UTC day.
Historical membership comes from these manifests, rather than the current
configuration. The first registration day includes unknown slots before setup.

## Schedule collection and daily reports

Configure the second host's scheduler as the probe account. Use an absolute path
to its `uv` executable. The following crontab assumes `/usr/local/bin/uv` and
GNU `date`; adjust them before installation. `CRON_TZ=UTC` requires a cron
implementation that supports it. Otherwise configure equivalent UTC jobs in
the host's existing scheduler.

```cron
CRON_TZ=UTC
*/5 * * * * cd /opt/monitoring && timeout 240 /usr/local/bin/uv run --no-project --python 3.15 scripts/uptime_evidence.py probe --store /var/lib/monitoring-uptime
17 0 * * * cd /opt/monitoring && /usr/local/bin/uv run --no-project --python 3.15 scripts/uptime_evidence.py summarize --store /var/lib/monitoring-uptime --date "$(date -u -d yesterday +\%F)"
```

The four-minute outer timeout bounds a stalled probe job, including DNS lookup.
An interrupted probe can leave targets unobserved; those slots remain unknown.
Monitor nonzero job exits with the host's existing job monitoring. A missing
schedule produces unknown intervals, not successful probes. A failed summary
job can be rerun for its original date. Reports reject conflicting replacements.

Back up the **entire evidence directory** to a separate destination using the
host's existing backup system. Retain at least six months. Do not prune raw
observations or manifests until their reports and backup copies are verified.
The hub's `just backup` does not include this directory.

## Read a historical period

```sh
uv run --no-project --python 3.15 scripts/uptime_evidence.py report --store /var/lib/monitoring-uptime --start 2026-01-01 --end 2026-06-30
```

Use dates covered by registered inventories. Reports count expected five-minute
slots separately as successful, failed or unknown. Compare success against
expected slots to avoid hiding gaps; success among observed slots describes
only measured requests. Keep coverage alongside any percentage.

The result measures HTTP reachability from the named probe location. It does
not establish continuous availability between probes, application correctness,
or availability from every user's network. Keep it separate from hub probes
and request-based service indicators. An outage of the probe host creates
unknown evidence. It cannot retrospectively establish uptime before collection.

To prove recovery after hub replacement, restore the evidence directory on a
clean second host and rerun the historical report. Compare its JSON with the
original output. No connection to Prometheus should be necessary.
