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

## 2026-11-25 — La UI /chat exige el servicio nomad_ollama "instalado"

- Contexto: con `ai.remoteOllamaUrl` apuntando a llama.cpp, el endpoint
  `/api/ollama/chat` respondía bien pero `http://localhost:8090/chat` devolvía
  `{"error":"AI Assistant service not installed"}`.
- Descubrimiento: `ChatsController.inertia()` usa
  `SystemService.checkServiceInstalled(SERVICE_NAMES.OLLAMA)`, que consulta la
  columna `installed` de la tabla `services` (fila `nomad_ollama`). Sin contenedor
  Ollama local hay que marcarla a mano. `_syncContainersWithDatabase()` no la
  revierte si existe `ai.remoteOllamaUrl`.
- Comandos relevantes:
  ```bash
  docker exec nomad_mysql mysql -unomad_user -p"$DB_PASS" nomad \
    -e "UPDATE services SET installed=1, installation_status='idle' WHERE service_name='nomad_ollama';"
  ```
- Cómo aplicarlo en el futuro: al configurar un backend remoto, fijar primero la
  URL y después marcar el servicio instalado; reiniciar la pestaña del navegador.

## 2026-11-25 — Streaming con Qwen3-4B parece colgado pero solo está razonando

- Contexto: en la UI el chat mostraba "Thinking" y el request
  `POST /api/ollama/chat` quedaba `pending` durante ~45 s.
- Descubrimiento: llama.cpp emite chunks vacíos mientras el modelo razona; el
  contenido llega al final. `think:false` suprime el texto de razonamiento, no
  el tiempo de cómputo. Con `curl -N` y filtrando líneas vacías se ve
  `content: "H"` y `content: "OLA"` al terminar.
- Cómo aplicarlo en el futuro: esperar antes de dar el chat por fallido; para
  pruebas rápidas usar `stream:false`.

## 2026-11-25 — RAG funciona con llama.cpp si se separa embeddings y se une con un proxy

- Contexto: NOMAD solo acepta una `ai.remoteOllamaUrl`, pero `RagService` llama
  a `/v1/embeddings` y el chat a `/v1/chat/completions`; los `llama-server`
  iniciales no tenían `--embeddings`.
- Descubrimiento: se levantó un segundo `llama-server` con
  `nomic-embed-text-v1.5.Q5_K_M.gguf` (768 dims) en 11436 y nginx en 11437
  enrutando por endpoint. Además, `RagService` busca el modelo
  `nomic-embed-text:v1.5` en `getModels(true)`; como llama.cpp solo lista su
  GGUF, hay que devolver un `/v1/models` estático con ese nombre o intenta
  descargarlo y falla. Qdrant se instala con
  `POST /api/system/services/install {"service_name":"nomad_qdrant"}`.
- Comandos relevantes:
  ```bash
  curl -s http://127.0.0.1:8090/api/rag/health     # {"online":true}
  curl -s -X POST http://127.0.0.1:8090/api/rag/upload -F 'file=@/tmp/mi_doc.txt'
  curl -s http://127.0.0.1:8090/api/rag/files      # state: indexed
  ```
- Cómo aplicarlo en el futuro: mantener `nomad-llama-embeddings.service` y el
  proxy nginx; con `rag.enabled=true` el chat recovery fragmentos y devuelve
  `sources`. Prueba real: al subir un TXT con `TORONJA-741` y preguntar por él,
  el modelo respondió el código correcto citando el archivo.

## 2026-11-25 — El tema oscuro se guarda en localStorage, no se lee del KV

- Contexto: se fijó `ui.theme=dark` en el KV de MySQL y se preguntó si podía
  ponerse oscura la interfaz.
- Descubrimiento: `admin/inertia/hooks/useTheme.ts` inicializa desde
  `localStorage['nomad:theme']` (por defecto `light`) y solo **escribe** el KV
  `ui.theme` de forma fire-and-forget. El botón se llama `Night Ops` /
  `Day Ops` (`ThemeToggle.tsx`). Por eso en un navegador nuevo hay que pulsar
  el botón una vez; el KV no basta.
- Cómo aplicarlo en el futuro: para activarlo por consola,
  `localStorage.setItem('nomad:theme','dark')` y recargar. Para persistir entre
  dispositivos haría falta parchear el frontend para leer `ui.theme` al arrancar.

## 2026-11-25 — Con 8 GB de RAM conviene el modelo de 1,7B, no el de 4B

- Contexto: Qwen3-4B-Q4_K_M.gguf en 11435 consume ~2,7 GB de RAM; con NOMAD,
  Qdrant, MySQL, Redis y el navegador el sistema tenía 5,9/7,5 GB usados y solo
  1,6 GB disponibles. Las respuestas de la UI tardaban 37–165 s.
- Descubrimiento: el servidor de 18020 ya tenía Qwen3-1.7B-Q4_K_M.gguf cargado
  (RSS ~7 MB en reposo). Al detener el de 4B y enrutar el proxy 11437 a 18020,
  la memoria disponible subió a ~3,9 GB y una respuesta simple bajó a ~20 s.
- Cómo aplicarlo en el futuro: en equipos de 8 GB usar el modelo de 1,7B para
  chat; el modelo de embeddings (95 MB) y Qdrant son los que aportan el
  conocimiento vía RAG, así que reducir el chat no pierde calidad factual.

## 2026-11-25 — `/opt/project-nomad/storage/zim` puede quedar en root:root

- Contexto: al descargar ZIMs con `curl -o` desde el usuario salía
  `Permiso denegado` aunque el directorio se había creado antes.
- Descubrimiento: el directorio estaba `root:root 755` (probablemente por el
  `sudo cp` del ZIM mini y/o el entrypoint del contenedor). Basta con
  `sudo chown botxtrem:botxtrem /opt/project-nomad/storage/zim` para poder
  escribir como usuario normal; los archivos deben quedar legibles (644) para
  que NOMAD los indexe.
- Cómo aplicarlo en el futuro: verificar `ls -ld` antes de una descarga
  directa; si no, usar `sudo curl` o la API `/api/zim/download-remote`.
