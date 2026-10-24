#!/bin/sh
# Entrypoint para Hermes na Guara Cloud (container sem privilégios, UID 1000).
#
# Descobertas que definiram este script:
#  1. s6-overlay (o /init oficial da imagem) aborta com
#     "fatal: /run belongs to uid 0 instead of 1000" — a Guara monta /run como
#     tmpfs do root, e o preinit do s6 exige que /run pertença ao usuário atual.
#  2. docker/main-wrapper.sh recusa explicitamente UID não-root que não seja o
#     usuário `hermes` ("container started with --user 1000 ... not supported").
#  Portanto: nem /init nem main-wrapper. Chamamos o CLI do venv direto.
#
# O Tailscale roda em modo userspace (sem /dev/net/tun e sem CAP_NET_ADMIN) e
# nunca bloqueia o processo principal — senão a readiness probe derruba o pod.
set -e

TS_DIR="${TS_STATE_DIR:-$HERMES_HOME/tailscale}"
TS_SOCK="$TS_DIR/tailscaled.sock"
TS_STATE="$TS_DIR/tailscaled.state"
APP_PORT="${PORT:-8080}"
HERMES_BIN="/opt/hermes/.venv/bin/hermes"

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

  echo "[guara] rede do tailnet em segundo plano; subindo o dashboard agora"
fi

if [ ! -x "$HERMES_BIN" ]; then
  echo "[guara] ERRO: $HERMES_BIN nao existe; conteudo de /opt/hermes/.venv/bin:" >&2
  ls /opt/hermes/.venv/bin 2>&1 | head -20 >&2
  exit 1
fi

exec "$HERMES_BIN" dashboard --host 0.0.0.0 --port "$APP_PORT" --no-open
