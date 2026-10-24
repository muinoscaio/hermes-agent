#!/bin/sh
# Entrypoint para Hermes na Guara Cloud (container sem privilégios, UID 1000).
#
# Descobertas que definiram este script:
#  1. s6-overlay (o /init oficial da imagem) aborta com
#     "fatal: /run belongs to uid 0 instead of 1000" — a Guara monta /run como
#     tmpfs do root, e o preinit do s6 exige que /run pertença ao usuário atual.
#  2. docker/main-wrapper.sh recusa UID não-root arbitrário ("not supported").
#     Portanto: nem /init nem main-wrapper; chamamos o CLI do venv direto.
#
# O Tailscale roda em modo userspace (sem /dev/net/tun e sem CAP_NET_ADMIN) e
# nunca bloqueia o processo principal.
#
# Modo de operação:
#  - HERMES_GATEWAY=1 -> dashboard em background (readiness probe da porta) +
#                        gateway (Telegram etc.) em foreground.
#  - caso contrário   -> dashboard em foreground.
#
# Ferramentas instaladas por npm (codex, claude, etc.) vivem em /data/tools:
# o sistema de arquivos da imagem é READ-ONLY para o UID 1000 e instalar em
# $HOME enche o disco efêmero do pod (o pod é EVICTADO com evicted_storage).
set -e

TS_DIR="${TS_STATE_DIR:-$HERMES_HOME/tailscale}"
TS_SOCK="$TS_DIR/tailscaled.sock"
TS_STATE="$TS_DIR/tailscaled.state"
APP_PORT="${PORT:-8080}"
HERMES_BIN="/opt/hermes/.venv/bin/hermes"

# npm/npx: binários e cache no volume persistente, nunca no overlay efêmero.
TOOLS_DIR="${HERMES_TOOLS_DIR:-/data/tools}"
mkdir -p "$TOOLS_DIR/.npm-cache" 2>/dev/null || true
export PATH="$TOOLS_DIR/node_modules/.bin:$PATH"
export npm_config_prefix="$TOOLS_DIR"
export npm_config_cache="$TOOLS_DIR/.npm-cache"
echo "[guara] PATH de ferramentas: $TOOLS_DIR/node_modules/.bin"

mkdir -p "$TS_DIR" 2>/dev/null || true

if [ -n "$TS_AUTHKEY" ]; then
  echo "[guara] tailscaled userspace em $TS_DIR"
  tailscaled \
    --tun=userspace-networking \
    --socket="$TS_SOCK" \
    --state="$TS_STATE" \
    --statedir="$TS_DIR" \
    --no-logs-no-support \
    >>"$TS_DIR/tailscaled.log" 2>&1 &

  i=0
  while [ $i -lt 30 ]; do
    tailscale --socket="$TS_SOCK" status >/dev/null 2>&1 && break
    i=$((i + 1)); sleep 1
  done

  (
    timeout 120 tailscale --socket="$TS_SOCK" up \
      --authkey="$TS_AUTHKEY" \
      --hostname="${TS_HOSTNAME:-hermes-guara}" \
      --accept-dns=false \
      --accept-routes=false >>"$TS_DIR/up.log" 2>&1 \
      || echo "[guara] up expirou/falhou (ver up.log)"

    j=0
    while [ $j -lt 45 ]; do
      case "$(tailscale --socket="$TS_SOCK" status --json 2>/dev/null | grep -o '"BackendState": *"[^"]*"' | head -1)" in
        *Running*) break ;;
      esac
      j=$((j + 1)); sleep 2
    done

    if [ -n "$TS_SERVE" ]; then
      tailscale --socket="$TS_SOCK" serve --bg --http=80 "http://127.0.0.1:$APP_PORT" \
        >>"$TS_DIR/serve.log" 2>&1 \
        && echo "[guara] serve ok: http://${TS_HOSTNAME:-hermes-guara} (tailnet) -> 127.0.0.1:$APP_PORT" \
        || echo "[guara] serve falhou (ver serve.log)"
    fi
  ) &

  echo "[guara] rede do tailnet em segundo plano"
fi

if [ ! -x "$HERMES_BIN" ]; then
  echo "[guara] ERRO: $HERMES_BIN nao existe" >&2
  ls /opt/hermes/.venv/bin 2>&1 | head -20 >&2
  exit 1
fi

if [ -n "$HERMES_GATEWAY" ]; then
  echo "[guara] dashboard em background na porta $APP_PORT; gateway em foreground"
  "$HERMES_BIN" dashboard --host 0.0.0.0 --port "$APP_PORT" --no-open \
    >>"$TS_DIR/dashboard.log" 2>&1 &
  sleep 2
  exec "$HERMES_BIN" gateway run
fi

exec "$HERMES_BIN" dashboard --host 0.0.0.0 --port "$APP_PORT" --no-open
