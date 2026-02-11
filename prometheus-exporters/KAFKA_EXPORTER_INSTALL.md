# Kafka Exporter Installation (VM / Instance)

**Scope:** This document covers installing the Kafka exporter on **VMs and bare-metal instances only**. For Kubernetes, use the separate Kafka exporter documentation.

This guide describes how to install and configure the Kafka exporter using the OpsVerse Prometheus exporter installers, and summarizes the installer changes for maintainers.

---

## Overview

The Kafka exporter enables monitoring of Apache Kafka clusters via Prometheus. This installer uses [danielqsj/kafka_exporter](https://github.com/danielqsj/kafka_exporter) version **1.9.0**.

Broker addresses are read from a config file at runtime. A wrapper script reads that file and starts the exporter with the appropriate `--kafka.server` arguments, so you can add or remove brokers by editing the file and restarting the service—no need to edit the systemd unit.

### Defaults

| Setting | Value |
|---------|-------|
| Kafka broker address (default) | `localhost:9092` |
| Broker list config file | `/etc/opsverse/exporters/kafka/kafka-brokers.conf` |
| Wrapper script | `/etc/opsverse/exporters/kafka/opsverse-kafka-exporter-start.sh` |
| Exporter metrics port | `9308` |
| Service name | `prom-kafka-exporter` |
| Binary location | `/usr/local/bin/kafka_exporter` |

**Important:** At least one broker listed in `kafka-brokers.conf` must be running and reachable when the service starts, or the exporter will fail to start.

---

## Changes Made

### 1. Validation and Help

- Added `kafka` to the exporter validation list (CLI accepts `-e kafka`)
- Added `kafka` to the help text under "Current list of supported exporters"

### 2. Download Logic (`download_exporter`)

- **Version:** 1.9.0
- **Source:** `https://github.com/danielqsj/kafka_exporter/releases/download/v1.9.0/kafka_exporter-1.9.0.linux-amd64.tar.gz`
- Downloads the tarball, extracts it, copies `kafka_exporter` to `/usr/local/bin/`, and cleans up temporary files

### 3. Broker List Config and Wrapper (`set_exporter_custom_confs`)

- **Broker list file:** `/etc/opsverse/exporters/kafka/kafka-brokers.conf`
  - Created only if it does not exist (re-running the installer does not overwrite it, so user edits are preserved).
  - Format: one broker per line (`host:port`). Blank lines and lines starting with `#` are ignored.
  - Default content: one line `localhost:9092` plus self-explanatory comments, including a note that at least one broker must be running and reachable for the exporter to start.

- **Wrapper script:** `/etc/opsverse/exporters/kafka/opsverse-kafka-exporter-start.sh`
  - Reads `kafka-brokers.conf`, builds `--kafka.server=...` for each valid line, and runs `exec /usr/local/bin/kafka_exporter ...`.
  - If no valid brokers are found in the file, defaults to `--kafka.server=localhost:9092`.
  - Installed with execute permission; overwritten on each installer run.

### 4. Systemd Service (`set_exporter_systemd`)

- Creates a systemd unit file at `/etc/systemd/system/prom-kafka-exporter.service`
- **ExecStart** runs the wrapper script: `/etc/opsverse/exporters/kafka/opsverse-kafka-exporter-start.sh` (not `kafka_exporter` directly)
- Service runs as root and auto-restarts on failure

### 5. SysV Init Support

- Added `kafka` to `exporter_needs_sysv` for systems without systemd
- SysV init script in `set_exporter_sysv` uses:
  - **EXPORTER_CONFIG:** `/etc/opsverse/exporters/kafka/kafka-brokers.conf`
  - **EXPORTER_COMMAND:** `/etc/opsverse/exporters/kafka/opsverse-kafka-exporter-start.sh`

### 6. Scrape Target (`set_exporter_scrape_target`)

- Creates `/etc/opsverse/targets/kafka-exporter.json` with:
  - Job label: `integrations/kafka-exporter`
  - Target: `localhost:9308`

---

## Installation Steps

### Prerequisites

- 64-bit Linux (AMD64 or ARM64)
- Root or sudo access
- `wget` installed
- At least one Kafka broker reachable from the host (default in config: `localhost:9092`)

### Install

**AMD64:**
```bash
cd prometheus-exporters/
sudo ./install-exporter-amd64.sh -e kafka
```

**ARM64** (e.g., Raspberry Pi, AWS Graviton):
```bash
cd prometheus-exporters/
sudo ./install-exporter-arm64.sh -e kafka
```

**Note:** If the Kafka exporter is already installed, stop the service before re-running the installer to avoid "Text file busy" when overwriting the binary:

```bash
sudo systemctl stop prom-kafka-exporter.service
sudo ./install-exporter-amd64.sh -e kafka
```

### Verify Installation

```bash
# Check service status
sudo systemctl status prom-kafka-exporter

# Verify metrics endpoint
curl http://localhost:9308/metrics
```

### Using a Different Kafka Broker or Multiple Brokers

Edit the broker list config file (do **not** edit the systemd unit):

```bash
sudo nano /etc/opsverse/exporters/kafka/kafka-brokers.conf
```

- One broker per line, e.g. `host:port`.
- Add or remove lines as needed. Blank lines and lines starting with `#` are ignored.
- Example for multiple brokers:

  ```
  kafka-broker1.example.com:9092
  kafka-broker2.example.com:9092
  ```

Then restart the service:

```bash
sudo systemctl restart prom-kafka-exporter
```

To see the current broker list:

```bash
cat /etc/opsverse/exporters/kafka/kafka-brokers.conf
```

### SASL authentication (optional)

For SASL-secured clusters, you need to pass extra flags to `kafka_exporter`. The service runs the wrapper script, which only adds `--kafka.server` from the config file. To add SASL (or TLS) options, edit the wrapper script and append the flags to the `exec` line:

```bash
sudo nano /etc/opsverse/exporters/kafka/opsverse-kafka-exporter-start.sh
```

Add SASL flags before the `exec` line is built, or append them to the `exec` call, for example:

```
exec /usr/local/bin/kafka_exporter ${ARGS} --sasl.enabled --sasl.username=your-username --sasl.password=your-password --sasl.mechanism=plain
```

SASL mechanisms: `plain`, `sha256`, `sha512`, `gssapi`, `awsiam`, `oauthbearer`.

**Note:** Re-running the installer overwrites the wrapper script, so any custom flags added there will be lost. For a permanent SASL setup, consider extending the installer to support a separate env or config file for extra exporter flags.

---

## Files Modified (for maintainers)

| File | Changes |
|------|---------|
| `install-exporter-amd64.sh` | Kafka exporter support: download, `kafka-brokers.conf`, wrapper script, systemd/SysV using wrapper, scrape target. Broker list and “at least one broker must be reachable” note in conf comments. |
| `install-exporter-arm64.sh` | Same Kafka logic for ARM64 (binary: `kafka_exporter-1.9.0.linux-arm64.tar.gz`): broker list file, wrapper script, systemd/SysV using wrapper. |

---

## Grafana Dashboard

A Grafana dashboard is available for Kafka exporter metrics:

- **Dashboard ID:** 7589
- **Name:** Kafka Exporter Overview
- **URL:** https://grafana.com/grafana/dashboards/7589-kafka-exporter-overview/
