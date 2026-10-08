#!/usr/bin/env bash
#
# Sobe o Prometheus dentro do cluster kind (k8s/monitoring) e abre um port-forward na
# porta 9091 do host (só em localhost). O Grafana do Compose lê esse Prometheus pelo
# datasource "Prometheus (kind)" (host.docker.internal:9091) e mostra as réplicas da API
# no cluster.
#
#   scripts/monitoring-up.sh          # aplica, espera ficar pronto e deixa o port-forward rodando
#   scripts/monitoring-up.sh --stop   # encerra o port-forward
#
# Por que port-forward e não NodePort: o kind só expõe no host as portas declaradas na
# criação do cluster (kind-cluster.yaml), e recriar o cluster para abrir mais uma porta
# não vale a pena num ambiente local. Idempotente: rodar de novo não duplica nada.

set -Eeuo pipefail

NAMESPACE="monitoring"
LOCAL_PORT="9091"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PID_FILE="${TMPDIR:-/tmp}/realworld-prometheus-port-forward.pid"

log() { printf '\n==> %s\n' "$*"; }

stop_forward() {
  if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    kill "$(cat "$PID_FILE")" && log "port-forward encerrado"
  fi
  rm -f "$PID_FILE"
}

if [[ "${1:-}" == "--stop" ]]; then
  stop_forward
  exit 0
fi

for bin in kubectl curl; do
  command -v "$bin" >/dev/null || { echo "ERRO: $bin não encontrado no PATH" >&2; exit 1; }
done

log "aplicando k8s/monitoring"
kubectl apply -k "$ROOT/k8s/monitoring"
kubectl -n "$NAMESPACE" rollout status deployment/prometheus --timeout=120s

stop_forward
log "port-forward localhost:$LOCAL_PORT -> svc/prometheus:9090 (em segundo plano)"
kubectl -n "$NAMESPACE" port-forward svc/prometheus "$LOCAL_PORT:9090" >/dev/null 2>&1 &
echo $! > "$PID_FILE"

for _ in $(seq 1 20); do
  if curl -fsS "http://localhost:$LOCAL_PORT/-/ready" >/dev/null 2>&1; then
    log "Prometheus do kind pronto em http://localhost:$LOCAL_PORT"
    echo "  alvos: http://localhost:$LOCAL_PORT/targets"
    echo "  encerrar o port-forward: scripts/monitoring-up.sh --stop"
    exit 0
  fi
  sleep 1
done

echo "ERRO: port-forward não respondeu em 20s" >&2
stop_forward
exit 1
