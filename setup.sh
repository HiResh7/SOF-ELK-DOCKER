#!/usr/bin/env bash
# =============================================================================
# SOF-ELK Docker - Full Setup Script
# Run once: sudo bash setup.sh
#
# Tested on: WSL2 (Ubuntu/Kali) + Docker Desktop for Windows
# Also works: Linux (native Docker), macOS + Docker Desktop
# ELK:       8.17.0
# SOF-ELK:   philhagen/sof-elk public/v20241217
# =============================================================================

set -euo pipefail

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
step()    { echo -e "\n${BOLD}${CYAN}━━━ $* ${NC}"; }

# ── Must run as root ──────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  error "Run as root: sudo bash setup.sh"
  exit 1
fi

REAL_USER="${SUDO_USER:-$USER}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Detect OS ─────────────────────────────────────────────────────────────────
OS="$(uname -s)"
# BSD sed (macOS) needs sed -i '', GNU sed (Linux) needs sed -i
if [[ "$OS" == "Darwin" ]]; then
  SED_INPLACE=(-i '')
else
  SED_INPLACE=(-i)
fi

echo -e "\n${BOLD}╔══════════════════════════════════════════════╗"
echo -e "║        SOF-ELK Docker Setup Script           ║"
echo -e "║        ELK 8.17.0 + SOF-ELK v20241217       ║"
echo -e "╚══════════════════════════════════════════════╝${NC}\n"

# ── Step 1: Prerequisites ─────────────────────────────────────────────────────
step "Step 1: Checking prerequisites"

for cmd in docker git curl jq openssl; do
  if command -v "$cmd" &>/dev/null; then
    success "$cmd found"
  else
    error "$cmd is required but not installed. Install it and re-run."
    exit 1
  fi
done

if ! docker info &>/dev/null; then
  error "Docker daemon is not running."
  error "Start Docker Desktop on Windows and ensure WSL integration is enabled."
  exit 1
fi
success "Docker daemon is running"

if docker compose version &>/dev/null; then
  COMPOSE_CMD="docker compose"
  success "docker compose (v2) found"
elif command -v docker-compose &>/dev/null; then
  COMPOSE_CMD="docker-compose"
  success "docker-compose (v1) found"
else
  error "docker compose not found."
  exit 1
fi

# ── Step 2: Kernel parameter (vm.max_map_count) ───────────────────────────────
step "Step 2: Configuring vm.max_map_count (required by Elasticsearch)"

if [[ "$OS" == "Darwin" ]]; then
  # On macOS, Docker runs in a Linux VM — set the param inside that VM
  info "macOS detected: setting vm.max_map_count inside Docker VM..."
  docker run --rm --privileged alpine sysctl -w vm.max_map_count=262144
  success "vm.max_map_count=262144 set inside Docker VM"
  warn "Note: this resets on Docker Desktop restart. To persist, add it in Docker Desktop → Settings → General → 'vm.max_map_count=262144' under resource settings."
else
  CURRENT_MAP=$(sysctl -n vm.max_map_count 2>/dev/null || echo "0")
  if [[ "$CURRENT_MAP" -lt 262144 ]]; then
    sysctl -w vm.max_map_count=262144
    if grep -q "vm.max_map_count" /etc/sysctl.conf 2>/dev/null; then
      sed "${SED_INPLACE[@]}" 's/^vm.max_map_count.*/vm.max_map_count=262144/' /etc/sysctl.conf
    else
      echo "vm.max_map_count=262144" >> /etc/sysctl.conf
    fi
    success "vm.max_map_count set to 262144 and persisted"
  else
    success "vm.max_map_count already $CURRENT_MAP (>= 262144)"
  fi
fi

# ── Step 3: Generate encryption keys and write .env ───────────────────────────
step "Step 3: Generating Kibana encryption keys"

cd "$SCRIPT_DIR"

KEY1=$(openssl rand -hex 16)
KEY2=$(openssl rand -hex 16)
KEY3=$(openssl rand -hex 16)

cat > .env << EOF
KIBANA_ENCKEY1=${KEY1}
KIBANA_ENCKEY2=${KEY2}
KIBANA_ENCKEY3=${KEY3}
EOF

# Also patch kibana.yml placeholders so the file itself is valid
sed "${SED_INPLACE[@]}" "s|PLACEHOLDER_REPLACED_BY_SETUP_SCRIPT_1|${KEY1}|g" kibana/kibana.yml
sed "${SED_INPLACE[@]}" "s|PLACEHOLDER_REPLACED_BY_SETUP_SCRIPT_2|${KEY2}|g" kibana/kibana.yml
sed "${SED_INPLACE[@]}" "s|PLACEHOLDER_REPLACED_BY_SETUP_SCRIPT_3|${KEY3}|g" kibana/kibana.yml

success "Encryption keys generated (32 chars each)"

# ── Step 4: Create directories ────────────────────────────────────────────────
step "Step 4: Creating directory structure"

mkdir -p data/elasticsearch data/filebeat
chmod 777 data/elasticsearch data/filebeat

LOG_DIRS=(syslog httpdlog zeek netflow passivedns kape plaso aws azure gcp evtxlogs json)
for d in "${LOG_DIRS[@]}"; do
  mkdir -p "logs/$d"
done

chown -R "$REAL_USER:$REAL_USER" logs/ data/ 2>/dev/null || true
success "Directories created"

info "Drop evidence files into:"
for d in "${LOG_DIRS[@]}"; do
  echo "    ${SCRIPT_DIR}/logs/${d}/"
done

# ── Step 5: Pull base images ──────────────────────────────────────────────────
step "Step 5: Pulling Docker images"

for img in \
  "docker.elastic.co/elasticsearch/elasticsearch:8.17.0" \
  "docker.elastic.co/kibana/kibana:8.17.0" \
  "docker.elastic.co/beats/filebeat:8.17.0"; do
  info "Pulling $img ..."
  docker pull "$img"
  success "Pulled $img"
done

# ── Step 6: Build custom Logstash image ───────────────────────────────────────
step "Step 6: Building custom Logstash image (SOF-ELK configs + plugins)"
info "Cloning philhagen/sof-elk and installing plugins — takes 3-5 minutes..."

$COMPOSE_CMD build --no-cache logstash
success "Custom Logstash image built: sof-elk-logstash:8.17.0"

# ── Step 7: Start the stack ───────────────────────────────────────────────────
step "Step 7: Starting the stack"

$COMPOSE_CMD up -d --remove-orphans
success "Stack started"

# ── Step 8: Wait for services ─────────────────────────────────────────────────
step "Step 8: Waiting for services to become healthy"

wait_healthy() {
  local container="$1" label="$2" timeout="${3:-240}"
  local elapsed=0 interval=5

  info "Waiting for $label..."
  while true; do
    status=$(docker inspect --format='{{.State.Health.Status}}' "$container" 2>/dev/null || echo "missing")
    case "$status" in
      healthy)  echo ""; success "$label is healthy"; return 0 ;;
      unhealthy) echo ""; error "$label is unhealthy — check: docker logs $container"; return 1 ;;
      missing)   echo ""; error "Container $container not found"; return 1 ;;
    esac
    sleep $interval
    elapsed=$((elapsed + interval))
    [[ $elapsed -ge $timeout ]] && { echo ""; error "$label timed out after ${timeout}s"; return 1; }
    echo -ne "\r  ${YELLOW}[${elapsed}s]${NC} Waiting for $label (${status})...   "
  done
}

wait_healthy "sof-elk-elasticsearch" "Elasticsearch" 180
wait_healthy "sof-elk-logstash"      "Logstash"      300
wait_healthy "sof-elk-kibana"        "Kibana"        240

# ── Step 9: Load SOF-ELK dashboards and templates ─────────────────────────────
step "Step 9: Loading SOF-ELK dashboards and index templates"
info "This loads ES templates, data views, and all Kibana dashboards..."

docker exec sof-elk-logstash bash -c '
  es_host=elasticsearch
  es_port=9200
  kibana_host=kibana
  kibana_port=5601
  kibana_version=8.17.0
  kibana_file_dir=/usr/local/sof-elk/kibana/
  sofelk_root_dir=/usr/local/sof-elk/

  echo "--- Loading ES component templates ---"
  for f in ${sofelk_root_dir}lib/elasticsearch_templates/component_templates/*.json; do
    name=$(echo $f | sed -e "s/.*\/component-\(.*\)\.json$/\1/")
    result=$(curl -s -o /dev/null -w "%{http_code}" -H "Content-Type: application/json" -X PUT http://${es_host}:${es_port}/_component_template/${name} -d @${f})
    echo "  ${name}: HTTP ${result}"
  done

  echo "--- Loading ES index templates ---"
  for f in ${sofelk_root_dir}lib/elasticsearch_templates/index_templates/*.json; do
    name=$(echo $f | sed "s/.*\/index-\(.*\)\.json/\1/")
    result=$(curl -s -o /dev/null -w "%{http_code}" -H "Content-Type: application/json" -X PUT http://${es_host}:${es_port}/_index_template/${name} -d @${f})
    echo "  ${name}: HTTP ${result}"
  done

  echo "--- Setting Kibana defaults ---"
  curl -s -o /dev/null -w "  HTTP %{http_code}\n" -H "kbn-xsrf: true" -H "Content-Type: application/json" \
    -X POST "http://${kibana_host}:${kibana_port}/api/saved_objects/config/${kibana_version}?overwrite=true" \
    -d@${kibana_file_dir}/sof-elk_config.json

  echo "--- Loading data views ---"
  for f in ${kibana_file_dir}/data_views/*.json; do
    id=$(basename $f | sed -e "s/\.json$//")
    curl -s -o /dev/null -H "kbn-xsrf: true" -H "Content-Type: application/json" -X DELETE "http://${kibana_host}:${kibana_port}/api/data_views/data_view/${id}"
    result=$(curl -s -o /dev/null -w "%{http_code}" -H "kbn-xsrf: true" -H "Content-Type: application/json" -X POST "http://${kibana_host}:${kibana_port}/api/data_views/data_view" -d@${f})
    echo "  ${id}: HTTP ${result}"
  done

  echo "--- Bulk loading dashboards, visualizations, lenses, maps, searches ---"
  TMPFILE=$(mktemp --suffix=.ndjson)
  for objecttype in visualization lens map search dashboard; do
    cat ${kibana_file_dir}/${objecttype}/*.json | jq -c "." >> $TMPFILE 2>/dev/null || true
  done
  result=$(curl -s -o /dev/null -w "%{http_code}" -H "kbn-xsrf: true" --form file=@$TMPFILE \
    -X POST "http://${kibana_host}:${kibana_port}/api/saved_objects/_import?overwrite=true")
  echo "  Bulk import: HTTP ${result}"
  rm -f $TMPFILE
  echo "--- Dashboard load complete ---"
'

success "SOF-ELK dashboards and templates loaded"

# ── Step 10: Final status ──────────────────────────────────────────────────────
step "Step 10: Final status"

$COMPOSE_CMD ps

echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════╗"
echo -e "║           SOF-ELK is ready!                     ║"
echo -e "╚══════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}Kibana:${NC}          http://localhost:5601"
echo -e "  ${BOLD}Elasticsearch:${NC}   http://localhost:9200"
echo -e "  ${BOLD}Logstash API:${NC}    http://localhost:9600"
echo ""
echo -e "  ${BOLD}Drop evidence files into:${NC}"
for d in "${LOG_DIRS[@]}"; do
  echo -e "    ${SCRIPT_DIR}/logs/${d}/"
done
echo ""
echo -e "  ${BOLD}Useful commands:${NC}"
echo -e "    Stop:        cd ${SCRIPT_DIR} && docker compose down"
echo -e "    Start:       cd ${SCRIPT_DIR} && docker compose up -d"
echo -e "    Logs:        docker logs -f sof-elk-logstash"
echo -e "    Wipe data:   docker compose down -v && rm -rf data/elasticsearch/* data/filebeat/*"
echo ""
