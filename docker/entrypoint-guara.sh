#!/bin/sh
# Entrypoint para rodar Hermes dentro de um container sem privilégios (Guara Cloud).
# Sobe o tailscaled em modo userspace (não precisa de /dev/net/tun nem CAP_NET_ADMIN),
# entra no tailnet com TS_AUTHKEY e publica o dashboard via `tailscale serve`.
# Depois entrega o controle ao entrypoint oficial do Hermes.
set -e

TS_DIR="${TS_STATE_DIR:-$HERMES_HOME/tailscale}"
TS_SOCK="$TS_DIR/tailscaled.sock"
TS_STATE="$TS_DIR/tailscaled.state"

mkdir -p "$TS_DIR" 2>/dev/null || true

if [ -n "$TS_AUTHKEY" ] || [ -n "$TS_SERVE" ]; then
  echo "[guara] iniciando tailscaled em modo userspace (dir: $TS_DIR)"
  tailscaled \
    --tun=userspace-networking \
    --socket="$TS_SOCK" \
    --state="$TS_STATE" \
    --statedir="$TS_DIR" \
    --no-logs-no-support \
    >>"$TS_DIR/tailscaled.log" 2>&1 &

  # espera o socket do daemon ficar pronto (até 30s)
  i=0
  while [ $i -lt 30 ]; do
    if tailscale --socket="$TS_SOCK" status >/dev/null 2>&1; then break; fi
    i=$((i + 1)); sleep 1
  done

  if [ -n "$TS_AUTHKEY" ]; then
    echo "[guara] entrando no tailnet como ${TS_HOSTNAME:-hermes-guara}"
    tailscale --socket="$TS_SOCK" up \
      --authkey="$TS_AUTHKEY" \
      --hostname="${TS_HOSTNAME:-hermes-guara}" \
      --accept-dns=false \
      --accept-routes=false \
      || echo "[guara] AVISO: tailscale up falhou (ver $TS_DIR/tailscaled.log)"
  fi

  # expõe o dashboard só dentro do tailnet, sem publicar na internet
  if [ -n "$TS_SERVE" ]; then
    APP_PORT="${PORT:-8080}"
    tailscale --socket="$TS_SOCK" serve --bg "http://127.0.0.1:$APP_PORT" \
      >>"$TS_DIR/serve.log" 2>&1 \
      && echo "[guara] tailscale serve ativo para 127.0.0.1:$APP_PORT" \
      || echo "[guara] AVISO: tailscale serve falhou (ver $TS_DIR/serve.log)"
  fi
fi

exec /opt/hermes/docker/entrypoint-dispatch.sh "$@"
