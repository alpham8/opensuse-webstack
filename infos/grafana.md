# Grafana Cloud — Dashboards & Monitoring

Workspace: <https://myorg.grafana.net>

---

## Data Sources

| UID                  | Type       | Purpose                                |
|----------------------|------------|----------------------------------------|
| grafanacloud-prom    | Prometheus | System metrics (CPU, RAM, Disk, ...)   |
| grafanacloud-logs    | Loki       | Logs (Journal, nginx, rkhunter, DMARC) |

Created automatically by Grafana Cloud once Alloy starts sending data.
Credentials are in ``etc/alloy/config.alloy``.

---

## Dashboards

### Folder: Integration - Linux Node (auto-created)

| Dashboard                        | Source       | Content                                       |
|----------------------------------|--------------|-----------------------------------------------|
| Linux node / overview            | Community    | Overview of all nodes                         |
| Linux node / fleet overview      | Community    | Fleet view                                    |
| Linux node / CPU and system      | Community    | CPU usage, load, context switches             |
| Linux node / memory              | Community    | RAM / Swap                                    |
| Linux node / filesystem and disks| Community    | Disk I/O, storage per partition               |
| Linux node / network             | Community    | Network traffic (in/out)                      |
| Linux node / logs                | Community    | System logs (Journal)                         |

### Folder: — (root)

| Dashboard           | UID           | Source                  | Content                                  |
|----------------------|---------------|-------------------------|------------------------------------------|
| Node Exporter Full   | rYdddlPWk    | Import ID **1860**      | Detailed system dashboard                |
| Endlessh             | ATIxYkO7k    | Import ID **15156**     | SSH tarpit statistics                    |

### Folder: Server Alerts (API-provisioned)

| Dashboard                | UID                | Data Source | Content                                                   |
|--------------------------|--------------------|-------------|-----------------------------------------------------------|
| Alloy Self-Monitoring    | alloy-self-monitoring | Prometheus  | Uptime, version, scrape duration, remote-write sent/failed|
| nginx Access Logs        | nginx-access-logs  | Loki        | Requests/min by status, method, vHost + log viewer        |
| nginx Error Logs         | nginx-error-logs   | Loki        | Error rate per vHost + log viewer                         |
| DMARC Aggregate Reports  | dmarc-reports      | Loki        | Disposition, DKIM/SPF alignment, reports per org/domain   |

---

## Alert Rules (Folder: Server Alerts, Group: Server Health)

| Alert                                | PromQL / Threshold             | Wait      | noData  |
|--------------------------------------|--------------------------------|-----------|---------|
| Disk > 85%                           | Root partition > 85% used      | 5 min     | Alerting|
| RAM > 90%                            | Available RAM < 10%            | 5 min     | Alerting|
| Systemd Service Down                 | nginx, php-fpm, mariadb, docker, crowdsec, postfix, alloy inactive | 2 min | Alerting|
| SSL Certificate expiring soon (<14d) | Cert expiry < 14 days          | 1 h       | OK      |
| No Alloy Heartbeat for 5 Min         | No metrics for 5 min           | 5 min     | Alerting|

Manage alerts: <https://myorg.grafana.net/alerting/list>

Contact Point: Default (Grafana Cloud notifications).
For email: add an email contact point under **Alerting -> Contact Points**.

---

## Import a Dashboard Manually

1. **Home -> Dashboards -> New -> Import**
2. Enter dashboard ID -> "Load"
3. Select data source -> "Import"

Useful community dashboard IDs:

| ID      | Name                                | Purpose                    |
|---------|-------------------------------------|----------------------------|
| 1860    | Node Exporter Full                  | Detailed system dashboard  |
| 15156   | Endlessh                            | SSH tarpit statistics      |
| 15172   | Node Exporter (compact)             | Compact system dashboard   |

---

## Useful Explore Queries (Quick Reference)

### Prometheus (Metrics)

```promql
# Uptime in days
node_time_seconds - node_boot_time_seconds

# Top 5 partitions by usage
topk(5, 100 - (node_filesystem_avail_bytes / node_filesystem_size_bytes * 100))

# Network traffic (bytes/s)
rate(node_network_receive_bytes_total{device="enp4s0"}[5m])
rate(node_network_transmit_bytes_total{device="enp4s0"}[5m])

# Load Average
node_load1 / node_load5 / node_load15

# Alloy running?
up{job="integrations/alloy-check"}

# endlessh active connections
endlessh_client_open_count_total
```

### Loki (Logs)

```logql
# All nginx access logs
{job="nginx-access"}

# Only 4xx/5xx errors
{job="nginx-access", status=~"4..|5.."}

# nginx error logs
{job="nginx-error"}

# Systemd Journal for a specific unit
{unit="sshd.service"}

# rkhunter warnings
{job="rkhunter"} |= `Warning`

# DMARC reports with failed SPF
{job="dmarc-reports"} | json | spf_align = `fail`

# Journal logs with error level
{transport="journal"} |= `error`
```

---

## Grafana Cloud Limits (Free Tier)

| Resource      | Limit                        |
|---------------|------------------------------|
| Metrics       | 10,000 active series         |
| Logs          | 50 GB / month                |
| Retention     | 14 days (metrics + logs)     |
| Alerting      | 100 alert rules              |
| Dashboards    | unlimited                    |
| Users         | 3                            |

Current usage: **Administration -> Usage & billing**

---

## API Access (Service Account)

Dashboards and alerts are managed via the Grafana API (service account token).
API documentation: <https://grafana.com/docs/grafana-cloud/developer-resources/api-reference/>
