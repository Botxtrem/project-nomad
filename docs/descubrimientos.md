# Descubrimientos

## 2026-11-25 — NOMAD + llama.cpp en el host con puerto 8080 ocupado

- Contexto: se clonó `Crosstalk-Solutions/project-nomad` y se quiso conectar a los
  servidores llama.cpp ya corriendo en `127.0.0.1:8080`, `:11435` y `:18020`.
- Descubrimiento: `install/install_nomad.sh` aborta en la preflight de puertos si
  el 8080 está ocupado, aunque instale Docker antes. Los contenedores se levantaron
  manualmente con el compose del repo mapeando `8090:8080`.
- Comandos / código relevante:
  ```bash
  docker compose -p project-nomad -f /opt/project-nomad/compose.yml up -d
  curl -s http://127.0.0.1:8090/api/health
  ```
- Cómo aplicarlo en el futuro: si 8080 está ocupado, no reintentar el instalador;
  generar `/opt/project-nomad/compose.yml` desde `install/management_compose.yaml`
  con `HOST_PORT` distinto y `URL=http://localhost:${HOST_PORT}`.

## 2026-11-25 — Contenedores no pueden hablar con llama.cpp en 127.0.0.1

- Contexto: los `llama-server` escuchan solo en loopback; `host.docker.internal`
  resuelve a la IP del gateway de Docker (`172.17.0.1`), no a loopback.
- Descubrimiento: un `socat TCP-LISTEN:<puerto>,bind=172.17.0.1,fork,reuseaddr
  TCP:127.0.0.1:<puerto>` expone el servicio únicamente a la red Docker, sin
  abrirlo a la LAN. Se dejó como servicio systemd `nomad-llama-bridge`.
- Cómo aplicarlo en el futuro: verificar desde el contenedor con
  `docker exec nomad_admin curl -s http://host.docker.internal:11435/v1/models`.

## 2026-11-25 — La URL del backend IA se memoiza al arrancar

- Contexto: cambiar `ai.remoteOllamaUrl` por API no bastó para que el chat usara
  el nuevo endpoint inmediatamente.
- Descubrimiento: `OllamaService._initialize()` guarda `initPromise`, `baseUrl` y
  el cliente `OpenAI`; el valor de KV se lee una sola vez por proceso. Hay que
  `docker restart nomad_admin` tras PATCH/UI.
- Comandos relevantes:
  ```bash
  curl -s -X PATCH http://127.0.0.1:8090/api/system/settings \
    -H 'Content-Type: application/json' \
    -d '{"key":"ai.remoteOllamaUrl","value":"http://host.docker.internal:11435"}'
  docker restart nomad_admin
  curl -s http://127.0.0.1:8090/api/ollama/installed-models
  ```
- Cómo aplicarlo en el futuro: siempre reiniciar `nomad_admin` después de cambiar
  el backend; los demás ajustes (modelo, RAG) se leen bajo demanda.

## 2026-11-25 — Llama.cpp no es backend Ollama nativo

- Contexto: al consultar modelos instalados aparecía el GGUF con `size: 0`.
- Descubrimiento: NOMAD prueba `/api/tags` para detectar Ollama; como llama.cpp
  responde distinto, usa `/v1/models` y marca el backend como no nativo. Efectos:
  no se pueden descargar modelos desde la UI y no se puede fijar `num_ctx` por
  petición. Tampoco hay embeddings, así que `rag.enabled` se puso en `false`.
- Cómo aplicarlo en el futuro: cargar modelos con `llama-server` en el host y
  dejar la descarga/contexto fuera de NOMAD; para RAG hace falta un servidor de
  embeddings separado.
