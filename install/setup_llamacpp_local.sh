#!/usr/bin/env bash
# Configure Project NOMAD to use host-only llama.cpp servers instead of Ollama.
# Reproduce: sudo bash install/setup_llamacpp_local.sh
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NOMAD_DIR="${NOMAD_DIR:-/opt/project-nomad}"
HOST_PORT="${HOST_PORT:-8090}"          # 8080 is taken by llama.cpp on this host
LLAMA_PORT="${LLAMA_PORT:-11435}"       # llama.cpp server to use (Qwen3-4B)
EMBED_PORT="${EMBED_PORT:-11436}"       # llama.cpp server with --embeddings
PROXY_PORT="${PROXY_PORT:-11437}"       # nginx: /v1/embeddings -> EMBED_PORT, rest -> LLAMA_PORT
BRIDGE_PORTS="${BRIDGE_PORTS:-8080 11435 11437 18020}"
MODEL_NAME="${MODEL_NAME:-/home/botxtrem/models/Qwen3-4B-Q4_K_M.gguf}"
EMBED_MODEL="${EMBED_MODEL:-/home/botxtrem/models/nomic-embed-text-v1.5.Q5_K_M.gguf}"
EMBED_MODEL_NAME="${EMBED_MODEL_NAME:-nomic-embed-text:v1.5}" # NOMAD hardcodes this name for RAG
BASE_URL="http://127.0.0.1:${HOST_PORT}"

command -v sudo >/dev/null || { echo "sudo is required"; exit 1; }
command -v docker >/dev/null || { echo "Docker is required (install it first)"; exit 1; }
command -v socat >/dev/null || { echo "socat is required (apt install socat)"; exit 1; }
command -v curl >/dev/null || { echo "curl is required"; exit 1; }
command -v openssl >/dev/null || { echo "openssl is required"; exit 1; }
command -v nginx >/dev/null || { echo "nginx is required (apt install nginx)"; exit 1; }

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

echo "==> Preparing embeddings server (${EMBED_MODEL})"
if [[ ! -f "${EMBED_MODEL}" ]]; then
  curl -fL --retry 3 -o "${EMBED_MODEL}" \
    https://huggingface.co/nomic-ai/nomic-embed-text-v1.5-GGUF/resolve/main/nomic-embed-text-v1.5.Q5_K_M.gguf
fi
sudo tee /etc/systemd/system/nomad-llama-embeddings.service >/dev/null <<UNIT
[Unit]
Description=llama.cpp embeddings server (nomic-embed-text-v1.5) for Project NOMAD RAG
After=network.target

[Service]
Type=simple
User=$(whoami)
Group=$(id -gn)
WorkingDirectory=$(dirname "${EMBED_MODEL}")
ExecStart=/home/botxtrem/tools/llama.cpp/build/bin/llama-server -m ${EMBED_MODEL} --host 127.0.0.1 --port ${EMBED_PORT} -c 2048 -t 4 --embeddings
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
sudo systemctl daemon-reload
sudo systemctl enable --now nomad-llama-embeddings.service

echo "==> Preparing OpenAI-compatible proxy on 127.0.0.1:${PROXY_PORT}"
sudo tee /etc/nginx/conf.d/nomad-llama-proxy.conf >/dev/null <<'NGINX'
# Project NOMAD accepts one ai.remoteOllamaUrl; route by endpoint so chat and
# embeddings can use different llama.cpp servers.
server {
    listen 127.0.0.1:__PROXY_PORT__;
    server_name _;
    client_max_body_size 64m;

    location = /v1/embeddings {
        proxy_pass http://127.0.0.1:__EMBED_PORT__;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_read_timeout 300s;
    }

    # llama.cpp only lists its own model; advertise the embedding model too so
    # RagService can resolve it without trying to "pull" a model.
    location = /v1/models {
        default_type application/json;
        return 200 '{"object":"list","data":[{"id":"__MODEL_NAME__","object":"model","created":1700000000,"owned_by":"llama.cpp","capabilities":["completion"]},{"id":"__EMBED_MODEL_NAME__","object":"model","created":1700000000,"owned_by":"llama.cpp","capabilities":["embedding"]}]}';
    }

    location / {
        proxy_pass http://127.0.0.1:__LLAMA_PORT__;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_buffering off;
        proxy_read_timeout 600s;
    }
}
NGINX
sudo sed -i \
  -e "s|__PROXY_PORT__|${PROXY_PORT}|" \
  -e "s|__EMBED_PORT__|${EMBED_PORT}|" \
  -e "s|__LLAMA_PORT__|${LLAMA_PORT}|" \
  -e "s|__MODEL_NAME__|${MODEL_NAME}|" \
  -e "s|__EMBED_MODEL_NAME__|${EMBED_MODEL_NAME}|" \
  /etc/nginx/conf.d/nomad-llama-proxy.conf
sudo nginx -t
sudo systemctl enable --now nginx >/dev/null
sudo systemctl reload nginx

echo "==> Waiting for NOMAD API"
for _ in $(seq 1 60); do
  if curl -fsS --max-time 5 "${BASE_URL}/api/health" >/dev/null; then break; fi
  sleep 2
done
curl -fsS --max-time 5 "${BASE_URL}/api/health" >/dev/null || { echo "NOMAD did not become healthy"; exit 1; }

echo "==> Installing Qdrant (vector DB for the Knowledge Base)"
curl -fsS -X POST "${BASE_URL}/api/system/services/install" \
  -H 'Content-Type: application/json' \
  -d '{"service_name":"nomad_qdrant"}' >/dev/null || true
for _ in $(seq 1 60); do
  if docker inspect nomad_qdrant >/dev/null 2>&1 &&
     [[ "$(docker inspect -f '{{.State.Running}}' nomad_qdrant 2>/dev/null)" == "true" ]]; then
    break
  fi
  sleep 2
done

echo "==> Applying AI settings"
set_setting() {
  curl -fsS -X PATCH "${BASE_URL}/api/system/settings" \
    -H 'Content-Type: application/json' \
    -d "{\"key\":\"$1\",\"value\":\"$2\"}" >/dev/null
}
set_setting ai.remoteOllamaUrl "http://host.docker.internal:${PROXY_PORT}"
set_setting chat.lastModel "${MODEL_NAME}"
set_setting rag.enabled "true"
set_setting ui.theme "dark"

# The chat UI checks the `nomad_ollama` row in the services table, not the
# remote endpoint. With a remote backend there is no local container, so the
# flag has to be set manually; NOMAD keeps it because ai.remoteOllamaUrl is set.
echo "==> Marking AI Assistant (nomad_ollama) as installed"
DB_PASS="$(grep '^ *- DB_PASSWORD=' "${NOMAD_DIR}/compose.yml" | head -1 | cut -d= -f2)"
docker exec nomad_mysql mysql -unomad_user -p"${DB_PASS}" nomad \
  -e "UPDATE services SET installed=1, installation_status='idle' WHERE service_name='nomad_ollama';" \
  >/dev/null 2>&1

# OllamaService memoizes the backend at boot; restart so the URL takes effect.
docker restart nomad_admin >/dev/null
for _ in $(seq 1 60); do
  if curl -fsS --max-time 5 "${BASE_URL}/api/health" >/dev/null; then break; fi
  sleep 2
done

echo "==> Done"
echo "    UI:            ${BASE_URL}"
echo "    Chat:          ${BASE_URL}/chat"
echo "    Modelos:       curl -s ${BASE_URL}/api/ollama/installed-models"
echo "    RAG health:    curl -s ${BASE_URL}/api/rag/health"
echo "    Tema oscuro:   en la UI boton 'Night Ops' (se guarda en localStorage nomad:theme=dark)"
echo "    Ajustes:       docs/llamacpp-local.md"
