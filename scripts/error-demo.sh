#!/usr/bin/env bash
#
# Gera erros na API de propósito, para a demo de observabilidade: tráfego normal, banco
# fora do ar (a API responde 500 e /readyz 503), banco de volta. No Grafana: taxa de 5xx
# sobe, o painel de erros ganha linhas com stack trace e o volume de logs por nível muda.
#
#   scripts/error-demo.sh            # Compose: para e religa o container postgres
#   scripts/error-demo.sh --kind     # kind: escala o StatefulSet postgres para 0 e volta
#
# Variáveis: BASE (URL da API), NORMAL (requisições boas), ERRORS (requisições com banco fora).
#
# Decisões:
# - O erro vem de uma falha real de dependência, não de um endpoint fake de erro: é o
#   cenário que a readiness e o dashboard foram desenhados para mostrar.
# - O banco volta sempre, mesmo com Ctrl+C no meio (trap), para a demo não deixar o
#   ambiente quebrado.
# - Só curl e docker/kubectl; mostra o código HTTP de cada requisição para a plateia ver
#   a transição 200 -> 500 -> 200 no terminal enquanto o Grafana atualiza.

set -Eeuo pipefail

MODE="compose"
[[ "${1:-}" == "--kind" ]] && MODE="kind"

NORMAL="${NORMAL:-60}"
ERRORS="${ERRORS:-20}"
if [[ "$MODE" == "kind" ]]; then
  BASE="${BASE:-http://localhost:8080}"
else
  BASE="${BASE:-http://localhost:3000}"
fi

log()  { printf '\n==> %s\n' "$*"; }
# Com o banco fora, parte das requisições espera o pool do Prisma desistir antes de virar 500;
# o max-time alto evita contar isso como falha do curl (que imprimiria 000).
code() { curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$1" || true; }

db_down() {
  if [[ "$MODE" == "kind" ]]; then
    kubectl -n realworld scale statefulset postgres --replicas=0 >/dev/null
  else
    docker compose stop postgres >/dev/null 2>&1
  fi
}

db_up() {
  if [[ "$MODE" == "kind" ]]; then
    kubectl -n realworld scale statefulset postgres --replicas=1 >/dev/null
  else
    docker compose start postgres >/dev/null 2>&1
  fi
}

DB_IS_DOWN=false
cleanup() {
  if $DB_IS_DOWN; then
    log "religando o banco antes de sair"
    db_up
  fi
}
trap cleanup EXIT

command -v curl >/dev/null || { echo "ERRO: curl não encontrado" >&2; exit 1; }
if [[ "$MODE" == "kind" ]]; then
  command -v kubectl >/dev/null || { echo "ERRO: kubectl não encontrado" >&2; exit 1; }
else
  command -v docker >/dev/null || { echo "ERRO: docker não encontrado" >&2; exit 1; }
fi

log "demo de erros em $BASE (modo $MODE)"
printf 'readyz antes: %s\n' "$(code "$BASE/readyz")"

log "1/3 tráfego normal: $NORMAL requisições"
for i in $(seq 1 "$NORMAL"); do
  printf '%s ' "$(code "$BASE/api/articles?limit=5&offset=$((i % 7))")"
  (( i % 20 == 0 )) && echo
done
echo

log "2/3 banco fora do ar: $ERRORS requisições (esperado 500; /readyz em 503)"
db_down
DB_IS_DOWN=true
# espera a API perder a conexão (o pool do Prisma leva alguns segundos para notar)
for _ in $(seq 1 15); do
  [[ "$(code "$BASE/readyz")" == "503" ]] && break
  sleep 1
done
printf 'readyz com banco fora: %s\n' "$(code "$BASE/readyz")"
for i in $(seq 1 "$ERRORS"); do
  printf '%s ' "$(code "$BASE/api/tags")"
  (( i % 20 == 0 )) && echo
  sleep 0.3
done
echo

log "3/3 banco de volta"
db_up
DB_IS_DOWN=false
for _ in $(seq 1 60); do
  [[ "$(code "$BASE/readyz")" == "200" ]] && break
  sleep 1
done
printf 'readyz depois: %s\n' "$(code "$BASE/readyz")"
printf 'api/tags depois: %s\n' "$(code "$BASE/api/tags")"

log "pronto. No Grafana: taxa de 5xx, 'Erros da API' e 'Volume de logs por nível'."
echo "  Explore (Loki):       {service=\"api\"} | json | status >= 500"
echo "  Explore (Prometheus): sum by (route, status_code) (rate(http_requests_total[1m]))"
