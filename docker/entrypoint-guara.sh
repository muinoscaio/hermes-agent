#!/bin/sh
# Entrypoint para rodar Hermes num container sem privilégios (Guara Cloud).
#
# Regra de ouro: NADA aqui pode bloquear o processo principal. O dashboard tem
# de subir mesmo que o Tailscale demore ou falhe — senão a readiness probe da
# plataforma derruba o pod (foi o que aconteceu na 1a tentativa: `tailscale up`
# em foreground segurava o entrypoint e o pod nunca ficava ready).
set -e

TS_DIR="${TS_STATE_DIR:-$HERMES_HOME/tailscale}"
TS_SOCK="$TS_DIR/tailscaled.sock"
TS_STATE="$TS_DIR/tailscaled.state"
APP_PORT="${PORT:-8080}"

mkdir -p "$TS_DIR" 2>/dev/null || true

if [ -n "$TS_AUTHKEY" ]; then
  echo "[guara] tailscaled userspace em $TS_DIR"
  # --tun=userspace-networking: nao precisa de /dev/net/tun nem CAP_NET_ADMIN
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

  # Todo o trabalho de rede roda em segundo plano, com timeouts proprios.
  (
    timeout 120 tailscale --socket="$TS_SOCK" up \
      --authkey="$TS_AUTHKEY" \
      --hostname="${TS_HOSTNAME:-hermes-guara}" \
      --accept-dns=false \
      --accept-routes=false >>"$TS_DIR/up.log" 2>&1 \
      || echo "[guara] up terminou com erro/expirou (ver up.log)"

    echo "[guara] estado do no: $(tailscale --socket="$TS_SOCK" status --json 2>/dev/null | grep -o '"BackendState": *"[^"]*"' | head -1)"

    if [ -n "$TS_SERVE" ]; then
      j=0
      while [ $j -lt 45 ]; do
        case "$(tailscale --socket="$TS_SOCK" status --json 2>/dev/null | grep -o '"BackendState": *"[^"]*"' | head -1)" in
          *Running*) break ;;
        esac
        j=$((j + 1)); sleep 2
      done
      # --http=80 dispensa certificado TLS; acessivel so dentro do tailnet.
      tailscale --socket="$TS_SOCK" serve --bg --http=80 "http://127.0.0.1:$APP_PORT" \
        >>"$TS_DIR/serve.log" 2>&1 \
        && echo "[guara] serve ok: http://${TS_HOSTNAME:-hermes-guara} (tailnet) -> 127.0.0.1:$APP_PORT" \
        || echo "[guara] serve falhou (ver serve.log)"
    fi
  ) &

  echo "[guara] rede do tailnet em segundo plano; subindo o Hermes agora"
fi

exec /opt/hermes/docker/entrypoint-dispatch.sh "$@"
