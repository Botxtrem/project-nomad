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
| Backend IA configurado | `http://host.docker.internal:11435` (Qwen3-4B-Q4_K_M.gguf) |
| Modelo por defecto (`chat.lastModel`) | `/home/botxtrem/models/Qwen3-4B-Q4_K_M.gguf` |
| RAG | desactivado (`rag.enabled=false`), ver limitaciones |

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

Todos escuchan solo en `127.0.0.1`, por lo que los contenedores no pueden
conectarse directamente. Se creó un puente `socat` que los expone solo en la IP
del gateway de Docker (`172.17.0.1`), no en toda la LAN:

- Script: `/usr/local/bin/nomad-llama-bridge.sh`
- Servicio: `/etc/systemd/system/nomad-llama-bridge.service` (`enabled`, `Restart=always`)

Comandos:

```bash
systemctl status nomad-llama-bridge
ss -ltnp | grep 172.17.0.1
docker exec nomad_admin curl -s http://host.docker.internal:11435/v1/models
```

## Configuración aplicada en NOMAD

Los ajustes se guardan en la tabla KV de MySQL y se pueden consultar/cambiar por API:

```bash
BASE=http://127.0.0.1:8090

curl -s -X PATCH "$BASE/api/system/settings" -H 'Content-Type: application/json' \
  -d '{"key":"ai.remoteOllamaUrl","value":"http://host.docker.internal:11435"}'

curl -s -X PATCH "$BASE/api/system/settings" -H 'Content-Type: application/json' \
  -d '{"key":"chat.lastModel","value":"/home/botxtrem/models/Qwen3-4B-Q4_K_M.gguf"}'

curl -s -X PATCH "$BASE/api/system/settings" -H 'Content-Type: application/json' \
  -d '{"key":"rag.enabled","value":"false"}'

for k in ai.remoteOllamaUrl chat.lastModel rag.enabled; do
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
- RAG (subida de documentos) necesita un endpoint de embeddings. Estos
  `llama-server` se iniciaron sin `--embeddings`, así que se desactivó
  `rag.enabled`. Para usarlo haría falta levantar un servidor de embeddings y
  configurar el backend accordingly.
- El puerto 8080 de NOMAD se movió al 8090; las URLs guardadas en la UI y en el
  compose usan `http://localhost:8090`.
- Qwen3-4B razona antes de responder: el streaming emite muchos chunks vacíos y
  la primera respuesta de la UI puede tardar ~45 s. No es un error; el flag
  `think:false` solo quita el texto de razonamiento, no acelera el modelo.

## Reinstalación automatizada

`install/setup_llamacpp_local.sh` reproduce la configuración (compose, puentes
socat, ajustes por API). Ver el script para variables `HOST_PORT`, `LLAMA_PORT`,
`BRIDGE_PORTS` y `MODEL_NAME`.
