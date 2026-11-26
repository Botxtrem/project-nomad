#!/usr/bin/env bash
# Configure Project NOMAD to use host-only llama.cpp servers instead of Ollama.
# Reproduce: sudo bash install/setup_llamacpp_local.sh
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NOMAD_DIR="${NOMAD_DIR:-/opt/project-nomad}"
HOST_PORT="${HOST_PORT:-8090}"          # 8080 is taken by llama.cpp on this host
LLAMA_PORT="${LLAMA_PORT:-11435}"       # llama.cpp server to use (Qwen3-4B)
BRIDGE_PORTS="${BRIDGE_PORTS:-8080 11435 18020}"
MODEL_NAME="${MODEL_NAME:-/home/botxtrem/models/Qwen3-4B-Q4_K_M.gguf}"
BASE_URL="http://127.0.0.1:${HOST_PORT}"

command -v sudo >/dev/null || { echo "sudo is required"; exit 1; }
command -v docker >/dev/null || { echo "Docker is required (install it first)"; exit 1; }
command -v socat >/dev/null || { echo "socat is required (apt install socat)"; exit 1; }
command -v curl >/dev/null || { echo "curl is required"; exit 1; }
command -v openssl >/dev/null || { echo "openssl is required"; exit 1; }

echo "==> Preparing ${NOMAD_DIR}"
sudo mkdir -p "${NOMAD_DIR}/storage/logs" "${NOMAD_DIR}/mysql" "${NOMAD_DIR}/redis"
sudo cp "${REPO_DIR}"/install/{start_nomad.sh,stop_nomad.sh,update_nomad.sh} "${NOMAD_DIR}/"
sudo chown -R "$(whoami):$(whoami)" "${NOMAD_DIR}"

if [[ ! -f "${NOMAD_DIR}/compose.yml" ]]; then
  echo "==> Generating compose.yml (host port ${HOST_PORT})"
  APP_KEY="$(openssl rand -hex 24)"
  DB_PASS="$(openssl rand -hex 20)"
  ROOT_PASS="$(openssl rand -hex 20)"
  cp "${REPO_DIR}/install/management_compose.yaml" "${NOMAD_DIR}/compose.yml"
  sed -i \
    -e "s|\"8080:8080\"|\"${HOST_PORT}:8080\"|" \
    -e "s|APP_KEY=replaceme|APP_KEY=${APP_KEY}|" \
    -e "s|URL=replaceme|URL=http://localhost:${HOST_PORT}|" \
    -e "s|DB_PASSWORD=replaceme|DB_PASSWORD=${DB_PASS}|" \
    -e "s|MYSQL_PASSWORD=replaceme|MYSQL_PASSWORD=${DB_PASS}|" \
    -e "s|MYSQL_ROOT_PASSWORD=replaceme|MYSQL_ROOT_PASSWORD=${ROOT_PASS}|" \
    "${NOMAD_DIR}/compose.yml"
  chmod 600 "${NOMAD_DIR}/compose.yml"
  echo "    secrets generated (APP_KEY=${APP_KEY:0:8}…, DB_PASS=${DB_PASS:0:8}…)"
else
  echo "==> Keeping existing ${NOMAD_DIR}/compose.yml"
fi

echo "==> Starting NOMAD containers"
docker compose -p project-nomad -f "${NOMAD_DIR}/compose.yml" up -d

echo "==> Installing llama.cpp bridge service"
sudo tee /usr/local/bin/nomad-llama-bridge.sh >/dev/null <<'SCRIPT'
#!/usr/bin/env bash
GW="$(docker network inspect bridge -f '{{(index .IPAM.Config 0).Gateway}}')"
for PORT in __BRIDGE_PORTS__; do
  nohup socat "TCP-LISTEN:${PORT},bind=${GW},fork,reuseaddr" "TCP:127.0.0.1:${PORT}" >/dev/null 2>&1 &
done
wait
SCRIPT
sudo sed -i "s|__BRIDGE_PORTS__|${BRIDGE_PORTS}|" /usr/local/bin/nomad-llama-bridge.sh
sudo chmod +x /usr/local/bin/nomad-llama-bridge.sh
sudo tee /etc/systemd/system/nomad-llama-bridge.service >/dev/null <<'UNIT'
[Unit]
Description=Bridge host-only llama.cpp servers into Docker for Project NOMAD
After=docker.service
Requires=docker.service

[Service]
Type=simple
ExecStart=/usr/local/bin/nomad-llama-bridge.sh
Restart=always

[Install]
WantedBy=multi-user.target
UNIT
sudo systemctl daemon-reload
sudo systemctl enable --now nomad-llama-bridge.service

echo "==> Waiting for NOMAD API"
for _ in $(seq 1 60); do
  if curl -fsS --max-time 5 "${BASE_URL}/api/health" >/dev/null; then break; fi
  sleep 2
done
curl -fsS --max-time 5 "${BASE_URL}/api/health" >/dev/null || { echo "NOMAD did not become healthy"; exit 1; }

echo "==> Applying AI settings"
set_setting() {
  curl -fsS -X PATCH "${BASE_URL}/api/system/settings" \
    -H 'Content-Type: application/json' \
    -d "{\"key\":\"$1\",\"value\":\"$2\"}" >/dev/null
}
set_setting ai.remoteOllamaUrl "http://host.docker.internal:${LLAMA_PORT}"
set_setting chat.lastModel "${MODEL_NAME}"
set_setting rag.enabled "false"

# OllamaService memoizes the backend at boot; restart so the URL takes effect.
docker restart nomad_admin >/dev/null
for _ in $(seq 1 60); do
  if curl -fsS --max-time 5 "${BASE_URL}/api/health" >/dev/null; then break; fi
  sleep 2
done

echo "==> Done"
echo "    UI:       ${BASE_URL}"
echo "    Modelos:  curl -s ${BASE_URL}/api/ollama/installed-models"
echo "    Ajustes:  docs/llamacpp-local.md"
