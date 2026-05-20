# SOF-ELK Docker

[![ELK Version](https://img.shields.io/badge/ELK-8.17.0-005571?logo=elasticstack&logoColor=white)](https://www.elastic.co/)
[![SOF-ELK](https://img.shields.io/badge/SOF--ELK-public%2Fv20241217-blue)](https://github.com/philhagen/sof-elk)
[![Platform](https://img.shields.io/badge/platform-WSL2%20%2B%20Docker%20Desktop-0db7ed?logo=docker&logoColor=white)](https://docs.docker.com/desktop/wsl/)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

> **One-command DFIR log analysis stack.** Drop evidence files in. Open Kibana. Hunt.

```
┌─────────────────────────────────────────────────────────────────────┐
│                        SOF-ELK DOCKER STACK                         │
│                                                                     │
│   Evidence Files          Ingest              Store        Visualize│
│                                                                     │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────┐  ┌────────┐  │
│  │  logs/zeek/  │    │              │    │          │  │        │  │
│  │  logs/kape/  │───▶│   Filebeat   │───▶│Logstash  │  │Kibana  │  │
│  │  logs/evtx/  │    │              │    │          │  │:5601   │  │
│  │  logs/aws/   │    └──────────────┘    │ SOF-ELK  │  │        │  │
│  │  logs/...    │                        │ Pipelines│  │Dashbds │  │
│  └──────────────┘                        │          │  │Discover│  │
│                                          └────┬─────┘  └───┬────┘  │
│                                               │             │       │
│                                          ┌────▼─────────────▼────┐  │
│                                          │     Elasticsearch      │  │
│                                          │        :9200           │  │
│                                          └───────────────────────┘  │
└─────────────────────────────────────────────────────────────────────┘
```

A fully automated Docker deployment of **[SOF-ELK](https://github.com/philhagen/sof-elk)** — the SANS DFIR ELK stack — running on ELK 8.17.0.  
One command brings up Elasticsearch, Logstash (with all SOF-ELK pipelines and dashboards), Kibana, and Filebeat, ready to ingest forensic evidence.

---

## What is SOF-ELK?

SOF-ELK is a pre-built ELK configuration maintained by [Phil Hagen](https://github.com/philhagen) (SANS FOR572) for Digital Forensics and Incident Response (DFIR). It ships with:

- **Logstash pipelines** for dozens of forensic log formats (Zeek, KAPE, Plaso, Windows Event Logs, cloud logs, etc.)
- **Kibana dashboards** purpose-built for threat hunting and log analysis
- **Elasticsearch index templates** tuned for security data

This repo wraps all of that in a Docker Compose stack so you can spin it up in minutes on any Windows machine with WSL2 and Docker Desktop — no VM, no manual ELK install.

---

## Prerequisites

| Requirement | Notes |
|---|---|
| [Docker](https://docs.docker.com/get-docker/) + [Docker Compose v2](https://docs.docker.com/compose/) | Docker Desktop (Windows/Mac) or Docker Engine (Linux) |
| RAM | 6 GB usable minimum, 8 GB+ recommended |
| Disk | 20 GB free for images + data |

**OS support:**
- **Windows** — WSL2 + Docker Desktop (tested). Enable WSL Integration in Docker Desktop → Settings → Resources → WSL Integration.
- **Linux** — works natively. `setup.sh` handles `vm.max_map_count` automatically.
- **Mac** — should work with Docker Desktop; `setup.sh` skips the Linux kernel step gracefully.

> WSL2 is not required — it's just the tested environment. The stack is pure Docker.

---

## Quick Start

Clone the repo inside your WSL2 distro:

```bash
git clone https://github.com/HiResh7/sof-elk-docker.git
cd sof-elk-docker
sudo bash setup.sh
```

That's it. The script will:

1. Check prerequisites (Docker, git, curl, jq, openssl)
2. Set `vm.max_map_count=262144` (required by Elasticsearch)
3. Generate random Kibana encryption keys and write a `.env` file
4. Create the `logs/` and `data/` directory structure
5. Pull all Docker images
6. Build the custom Logstash image (clones SOF-ELK repo + installs plugins, ~3–5 min)
7. Start the full stack
8. Wait for all services to become healthy
9. Load all SOF-ELK Elasticsearch templates, Kibana data views, and dashboards

When the script finishes, open **http://localhost:5601** — Kibana is ready.

---

## Ingest Log Files

Drop evidence files into `./logs/<type>/` and Filebeat will pick them up automatically:

| Directory | Log Type |
|---|---|
| `logs/syslog/` | Syslog / auth.log |
| `logs/httpdlog/` | Apache / HTTPD access logs |
| `logs/zeek/` | Zeek (Bro) JSON logs |
| `logs/netflow/` | NetFlow (nfdump output) |
| `logs/passivedns/` | Passive DNS |
| `logs/kape/` | KAPE JSON output |
| `logs/plaso/` | Plaso timeline output |
| `logs/aws/` | AWS CloudTrail, VPC Flow Logs, etc. |
| `logs/azure/` | Azure activity / sign-in logs |
| `logs/gcp/` | GCP audit logs |
| `logs/evtxlogs/` | Windows Event Logs (EVTX → JSON) |
| `logs/json/` | Generic JSON |

Logstash processes files in real time. Check ingestion progress in Kibana → Discover.

---

## Access

| Service | URL |
|---|---|
| Kibana | http://localhost:5601 |
| Elasticsearch | http://localhost:9200 |
| Logstash API | http://localhost:9600 |

No authentication is configured (security is disabled for local DFIR use).

---

## Common Commands

```bash
# Start the stack
docker compose up -d

# Stop the stack (data is preserved)
docker compose down

# View live Logstash logs
docker logs -f sof-elk-logstash

# Check health of all containers
docker compose ps

# Wipe all data and start fresh
docker compose down -v
rm -rf data/elasticsearch/* data/filebeat/*
docker compose up -d

# Reload SOF-ELK dashboards manually (if Kibana was wiped)
docker exec sof-elk-logstash bash -c 'cd /usr/local/sof-elk && bash load_all_dashboards.sh'
```

---

## Directory Structure

```
sof-elk-docker/
├── setup.sh                    ← run once to deploy everything
├── docker-compose.yml
├── elasticsearch/
│   └── elasticsearch.yml       ← Elasticsearch config
├── kibana/
│   └── kibana.yml              ← Kibana config (encryption keys patched by setup.sh)
├── logstash/
│   ├── Dockerfile              ← clones SOF-ELK repo + installs plugins
│   ├── logstash.yml            ← points pipeline to SOF-ELK configfiles
│   └── jvm.options             ← JVM heap settings
├── filebeat/
│   └── filebeat.yml            ← watches logs/ and ships to Logstash
├── logs/                       ← DROP EVIDENCE HERE (auto-created by setup.sh)
│   ├── syslog/
│   ├── zeek/
│   └── ...
└── data/                       ← persistent ES + Filebeat state (auto-created)
    ├── elasticsearch/
    └── filebeat/
```

---

## Troubleshooting

**Elasticsearch won't start / exits with error 137**
- Out of memory. Increase Docker Desktop memory limit: Settings → Resources → Memory (set to 6–8 GB+).

**`vm.max_map_count` warning**
- Run `sudo sysctl -w vm.max_map_count=262144` in WSL, or re-run `sudo bash setup.sh`.

**Kibana shows "Kibana server is not ready yet"**
- Elasticsearch may still be starting. Wait 1–2 minutes and refresh. Check: `docker logs sof-elk-elasticsearch`.

**Logstash build fails (git clone / plugin install)**
- Network issue during build. Retry: `docker compose build --no-cache logstash`.

**Files dropped in `logs/` are not appearing in Kibana**
- Check Logstash is healthy: `docker compose ps`
- Check Logstash logs for parse errors: `docker logs sof-elk-logstash`
- Verify the file is in the correct subdirectory for its type.

**`docker compose up` fails after a `docker compose down -v`**
- The `.env` file with Kibana encryption keys was written by `setup.sh`. Re-run `sudo bash setup.sh` to regenerate it.

---

## Credits

- [philhagen/sof-elk](https://github.com/philhagen/sof-elk) — the original SOF-ELK project by Phil Hagen (SANS)
- [Elastic](https://www.elastic.co/) — Elasticsearch, Logstash, Kibana, Filebeat

---

## License

MIT
