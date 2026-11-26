# NOMAD + llama.cpp local (instalación de BotXtrem)

Esta guía documenta cómo se instaló Project NOMAD en esta máquina (Parrot/Debian)
conectado a los servidores **llama.cpp** que ya corren en el host, en lugar de
Ollama. Todo se hizo con el repo `Crosstalk-Solutions/project-nomad` clonado en
`/home/botxtrem/projects/project-nomad`.

## Estado actual

| Item | Valor |
|---|---|
| Repo clonado | `/home/botxtrem/projects/project-nomad` |
| Instalación / datos | `/opt/project-nomad` |
| UI de NOMAD | <http://localhost:8090> |
| Logs de contenedores | <http://localhost:9999> (Dozzle) |
| Compose | `/opt/project-nomad/compose.yml` |
| Backend IA configurado | `http://host.docker.internal:11437` (proxy nginx: chat + embeddings) |
| Modelo por defecto (`chat.lastModel`) | `/home/botxtrem/models/Qwen3-4B-Q4_K_M.gguf` |
| RAG | activado (`rag.enabled=true`) con Qdrant + `nomic-embed-text:v1.5` |
| Tema | oscuro (`ui.theme=dark` + `localStorage nomad:theme=dark`) |

## Por qué no se usó el instalador oficial tal cual

`install/install_nomad.sh` hace una preflight de puertos y **falla si el 8080 está
ocupado**. En esta máquina el 8080 ya lo usa `llama-server` con
`Bonsai-8B-Q1_0.gguf`, así que el instalador instaló Docker pero se detuvo antes
de crear los contenedores. La solución fue levantar el compose manualmente
mapeando el puerto host `8090 -> 8080` del contenedor `admin`.

## Servidores llama.cpp disponibles en el host

| Puerto | Modelo |
|---|---|
| 8080 | `/home/botxtrem/models/Bonsai-8B-Q1_0.gguf` |
| 11435 | `/home/botxtrem/models/Qwen3-4B-Q4_K_M.gguf` (el usado por NOMAD) |
| 18020 | `/home/botxtrem/models/Qwen3-1.7B-Q4_K_M.gguf` |
| 11436 | `/home/botxtrem/models/nomic-embed-text-v1.5.Q5_K_M.gguf` (`--embeddings`) |
| 11437 | nginx, une chat (11435) + embeddings (11436) en una sola URL |

Todos escuchan solo en `127.0.0.1`, por lo que los contenedores no pueden
conectarse directamente. Se creó un puente `socat` que expone 8080, 11435,
11437 y 18020 solo en la IP del gateway de Docker (`172.17.0.1`), no en toda
la LAN:

- Script: `/usr/local/bin/nomad-llama-bridge.sh`
- Servicio: `/etc/systemd/system/nomad-llama-bridge.service` (`enabled`, `Restart=always`)

Comandos:

```bash
systemctl status nomad-llama-bridge nomad-llama-embeddings
ss -ltnp | grep 172.17.0.1
docker exec nomad_admin node -e "fetch('http://host.docker.internal:11437/v1/models').then(r=>r.text()).then(console.log)"
```

## Proxy chat + embeddings (11437)

NOMAD solo acepta **una** URL de backend (`ai.remoteOllamaUrl`), pero el RAG
necesita embeddings y el chat necesita generación. Se puso nginx en
`127.0.0.1:11437` con `/etc/nginx/conf.d/nomad-llama-proxy.conf`:

- `/v1/embeddings` → `127.0.0.1:11436` (modelo `nomic-embed-text-v1.5`, 768 dims).
- `/v1/models` → JSON estático con el modelo de chat y `nomic-embed-text:v1.5`.
  Sin esto, `RagService` no encuentra el modelo de embeddings e intenta
  "descargarlo" (imposible en llama.cpp).
- Todo lo demás (`/v1/chat/completions`, etc.) → `127.0.0.1:11435` (Qwen3-4B).
- `/api/tags` sigue devolviendo 404 para que NOMAD detecte el backend como
  "no Ollama nativo" y use directamente la API OpenAI-compatible.

El servicio `nomad-llama-embeddings.service` mantiene el servidor de embeddings
activo, y el puente socat expone el puerto 11437 a los contenedores.

## Configuración aplicada en NOMAD

Los ajustes se guardan en la tabla KV de MySQL y se pueden consultar/cambiar por API:

```bash
BASE=http://127.0.0.1:8090

curl -s -X PATCH "$BASE/api/system/settings" -H 'Content-Type: application/json' \
  -d '{"key":"ai.remoteOllamaUrl","value":"http://host.docker.internal:11437"}'

curl -s -X PATCH "$BASE/api/system/settings" -H 'Content-Type: application/json' \
  -d '{"key":"chat.lastModel","value":"/home/botxtrem/models/Qwen3-4B-Q4_K_M.gguf"}'

curl -s -X PATCH "$BASE/api/system/settings" -H 'Content-Type: application/json' \
  -d '{"key":"rag.enabled","value":"true"}'

for k in ai.remoteOllamaUrl chat.lastModel rag.enabled ui.theme; do
  curl -s "$BASE/api/system/settings?key=$k"; echo
done
```

`ai.remoteOllamaUrl` se lee en `admin/app/services/ollama_service.ts` (`KVStore`).
Cuando hay un valor personalizado, NOMAD usa `OpenAI({ baseURL: <url>/v1 })`;
si no, intenta usar el contenedor Ollama. El backend se memoiza al iniciar, por
eso hay que hacer `docker restart nomad_admin` tras cambiar la URL.

La página `/chat` además comprueba que el servicio `nomad_ollama` esté marcado
como instalado en la tabla `services` de MySQL. Como no hay contenedor Ollama,
se marcó a mano (NOMAD no lo revierte mientras exista `ai.remoteOllamaUrl`):

```bash
DB_PASS=$(grep '^ *- DB_PASSWORD=' /opt/project-nomad/compose.yml | head -1 | cut -d= -f2)
docker exec nomad_mysql mysql -unomad_user -p"$DB_PASS" nomad \
  -e "UPDATE services SET installed=1, installation_status='idle' WHERE service_name='nomad_ollama';"
```

Sin ese paso la UI responde `{"error":"AI Assistant service not installed"}`,
aunque la API `/api/ollama/chat` funcione.

Cambiar de modelo: basta con apuntar `ai.remoteOllamaUrl` a otro puenteado
(`8080` o `18020`) y actualizar `chat.lastModel` con el nombre que devuelva
`/v1/models`, seguido de `docker restart nomad_admin`.

## Base de conocimientos (RAG): cómo usarla

Requisitos ya montados: Qdrant (`nomad_qdrant`, contenedor Docker) y el
servidor de embeddings en 11436. Qdrant se instaló con:

```bash
curl -s -X POST http://127.0.0.1:8090/api/system/services/install \
  -H 'Content-Type: application/json' -d '{"service_name":"nomad_qdrant"}'
```

En la UI:

1. Abrir <http://localhost:8090/chat>.
2. En la barra superior, activar el interruptor **Knowledge Base**.
3. Subir archivos (PDF/TXT/MD) desde el panel de Knowledge Base; NOMAD los
   divide en chunks, llama a `/v1/embeddings` y guarda los vectores en Qdrant.
4. Hacer preguntas: el pipeline recupera los fragmentos relevantes y se los
   pasa a Qwen3-4B como contexto. La respuesta incluye las fuentes citadas.

Por API:

```bash
BASE=http://127.0.0.1:8090
curl -s "$BASE/api/rag/health"                       # {"online":true}
curl -s "$BASE/api/rag/collections"
curl -s -X POST "$BASE/api/rag/upload" -F 'file=@/tmp/mi_doc.txt'
curl -s "$BASE/api/rag/files"                        # estado: indexed
```

Prueba real hecha en esta máquina: se subió un TXT con el dato
`TORONJA-741` y se preguntó por él. El modelo respondió `TORONJA-741` y
devolvió en `sources` el nombre del archivo subido, confirmando que el
contexto recuperado llegó al modelo.

## Modo oscuro

El botón **Night Ops** (en la barra lateral / footer) cambia la interfaz a
oscuro. `useTheme.ts` guarda el valor en `localStorage nomad:theme=dark` y
escribe también el KV `ui.theme=dark`, pero **al cargar la página solo se lee
localStorage**: si abres NOMAD en otro navegador/perfil hay que pulsar una vez
el botón (o dejar `localStorage.setItem('nomad:theme','dark')` en la consola).
No hace falta reiniciar contenedores.

## Verificación

```bash
docker compose -p project-nomad -f /opt/project-nomad/compose.yml ps
curl -s http://127.0.0.1:8090/api/health
curl -s http://127.0.0.1:8090/api/ollama/installed-models

curl -s -X POST http://127.0.0.1:8090/api/ollama/chat \
  -H 'Content-Type: application/json' \
  -d '{"model":"/home/botxtrem/models/Qwen3-4B-Q4_K_M.gguf","messages":[{"role":"user","content":"Responde solo: OK"}],"stream":false,"think":false}'
```

## Comandos útiles

```bash
sudo bash /opt/project-nomad/start_nomad.sh
sudo bash /opt/project-nomad/stop_nomad.sh
sudo bash /opt/project-nomad/update_nomad.sh
docker compose -p project-nomad -f /opt/project-nomad/compose.yml logs -f admin
```

## Limitaciones

- NOMAD detecta el backend como "no Ollama nativo" (sondeo a `/api/tags`), por lo
  que no puede descargar modelos desde la UI ni fijar `num_ctx` por petición.
  Los modelos se cargan con `llama-server` en el host.
- El modelo de embeddings se sirve en un proceso separado: si se detiene
  `nomad-llama-embeddings.service`, el chat sigue funcionando pero la base de
  conocimientos deja de poder indexar/consultar.
- El puerto 8080 de NOMAD se movió al 8090; las URLs guardadas en la UI y en el
  compose usan `http://localhost:8090`.
- Qwen3-4B razona antes de responder: el streaming emite muchos chunks vacíos y
  la primera respuesta de la UI puede tardar ~45 s. No es un error; el flag
  `think:false` solo quita el texto de razonamiento, no acelera el modelo.

## Reinstalación automatizada

`install/setup_llamacpp_local.sh` reproduce la configuración (compose, puentes
socat, servidor de embeddings, proxy nginx, instalación de Qdrant y ajustes por
API). Variables: `HOST_PORT`, `LLAMA_PORT`, `EMBED_PORT`, `PROXY_PORT`,
`BRIDGE_PORTS`, `MODEL_NAME`, `EMBED_MODEL` y `EMBED_MODEL_NAME`.
