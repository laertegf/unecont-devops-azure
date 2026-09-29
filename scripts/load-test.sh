#!/usr/bin/env bash
#
# Gera carga na API de dentro do cluster para demonstrar o HPA escalando.
#
#   scripts/load-test.sh [workers] [segundos]     # padrão: 8 workers por 180s
#
# A carga roda num namespace separado ("loadtest"): o namespace da aplicação exige o
# perfil "restricted" do Pod Security, e um gerador de carga descartável não precisa
# passar por esse crivo. Ao fim (ou com Ctrl+C) o pod é removido.

set -Eeuo pipefail

WORKERS="${1:-8}"
DURATION="${2:-180}"
TARGET="http://api.realworld.svc.cluster.local/api/articles"

cleanup() { kubectl -n loadtest delete pod loadgen --ignore-not-found --wait=false >/dev/null 2>&1 || true; }
trap cleanup EXIT

kubectl create namespace loadtest --dry-run=client -o yaml | kubectl apply -f - >/dev/null
cleanup
sleep 2

echo "==> $WORKERS workers batendo em $TARGET por ${DURATION}s"
kubectl -n loadtest run loadgen --image=busybox:1.37 --restart=Never -- \
  sh -c "for i in \$(seq 1 $WORKERS); do (while true; do wget -q -O /dev/null $TARGET; done) & done; sleep $DURATION"

end=$((SECONDS + DURATION))
while (( SECONDS < end )); do
  echo
  date +%H:%M:%S
  kubectl -n realworld get hpa api \
    -o jsonpath='HPA: uso de CPU {.status.currentMetrics[0].resource.current.averageUtilization}% (alvo {.spec.metrics[0].resource.target.averageUtilization}%)   réplicas {.status.currentReplicas} -> {.status.desiredReplicas}{"\n"}'
  kubectl -n realworld top pods -l app.kubernetes.io/name=realworld-api 2>/dev/null || true
  sleep 15
done

echo
echo "==> carga encerrada; o HPA reduz as réplicas depois da janela de estabilização (60s)"
