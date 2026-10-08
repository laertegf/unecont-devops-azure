#!/usr/bin/env bash
#
# deploy.sh — publica uma imagem num Deployment, espera o rollout, VERIFICA a versão nova
# atendendo de verdade (smoke test + taxa de erro e latência no Prometheus) e, se qualquer
# etapa falhar, volta para a última versão comprovadamente boa — não para "a anterior".
#
# Uso:
#   scripts/deploy.sh <imagem> [opções]
#   scripts/deploy.sh --rollback [opções]      # volta para a última versão comprovada
#
# Opções (padrões entre parênteses):
#   -n namespace (realworld)   -d deployment (api)   -c containers (api,migrate)
#   -s service que expõe o deployment (api)   -t timeout do rollout (120s)
#   -u URL da API para smoke test e tráfego de verificação (http://localhost:8080; "" desliga)
#   -p URL do Prometheus que coleta os pods (http://localhost:9091; "" desliga a análise)
#   -w janela de verificação, em segundos (60)
#   -e taxa máxima de 5xx, em % (1)      -l latência p95 máxima, em ms (500)
#
# Exemplos:
#   scripts/deploy.sh ghcr.io/laertegf/unecont-devops-azure:sha-1a2b3c4
#   scripts/deploy.sh ghcr.io/laertegf/unecont-devops-azure:nao-existe -t 60s   # ImagePullBackOff → rollback
#   scripts/deploy.sh realworld-api:com-falha -w 30                             # sobe Ready, erra → rollback
#   scripts/deploy.sh --rollback                                                # volta para a última boa
#
# Códigos de saída (pensados para quem chama o script, ex.: um pipeline):
#   0  versão no ar e aprovada (ou nada a fazer; ou sem como verificar, com aviso)
#   1  erro de uso ou pré-condição (sem kubectl, Deployment inexistente...)
#   2  falhou (rollout ou verificação), rollback feito e a versão boa está saudável
#   3  falhou e o rollback também falhou: precisa de gente olhando AGORA
#
# Por que não basta "voltar a imagem anterior" — e o que este script faz no lugar:
#
# 1. ALVO. A versão anterior pode estar tão ruim quanto a atual: dois deploys ruins
#    seguidos, ou um "kubectl set image" feito na mão fora do pipeline. O script só
#    registra uma versão como boa (anotações deploy.realworld.io/last-good-*) depois que
#    ela passou na verificação; o rollback volta para ESSA versão, por revisão quando ela
#    ainda está no histórico, por imagem quando não está. Sem nenhuma versão comprovada,
#    cai na revisão anterior, avisando.
#
# 2. GATILHO. "kubectl rollout status" só diz que os pods passaram na readiness. Uma
#    versão que sobe, fica Ready e devolve 500 (ou demora) fica no ar até alguém reclamar.
#    Depois do rollout, o script roda o smoke test e, por uma janela, mede no Prometheus a
#    taxa de 5xx e o p95 SÓ DOS PODS DA VERSÃO NOVA (filtro pelo hash do ReplicaSet).
#    Reprovou em qualquer um: rollback. É a versão manual de um AnalysisTemplate do
#    Argo Rollouts; em produção, a ferramenta faz isso com canário e divisão de tráfego.
#
# 3. BANCO. Rollback de imagem não desfaz migração, e o Prisma não tem "down". O script
#    compara a tabela _prisma_migrations antes e depois do deploy e, no rollback, lista as
#    migrações que entraram: a versão antiga passa a rodar sobre o schema novo. Isso só é
#    seguro com migrações compatíveis com a versão anterior (expand/contract); se não
#    forem, o rollback do schema é uma decisão humana, e o script diz isso em vez de fingir.
#
# 4. ROLLBACK TAMBÉM É DEPLOY. "--rollback" passa pela mesma verificação: voltar para uma
#    versão que já não funciona (schema mudou, dependência externa mudou) é um deploy ruim
#    como outro qualquer.
#
# Decisões herdadas:
# - Bash + kubectl + curl, sem jq/yq/helm. Roda igual no runner, num bastion ou no Git Bash.
# - O timeout do rollout é explícito: sem ele, ImagePullBackOff fica pendurado até o
#   progressDeadlineSeconds (10 min).
# - Diagnóstico ANTES do rollback, senão o motivo da falha some junto com os pods.
# - API e initContainer de migração vêm do mesmo artefato e são atualizados juntos (-c).
# - maxUnavailable: 0 no Deployment: enquanto a versão nova não fica pronta, as réplicas
#   antigas continuam atendendo.

set -Eeuo pipefail

NAMESPACE="realworld"
DEPLOYMENT="api"
SERVICE="api"
CONTAINERS="api,migrate"
TIMEOUT="120s"
URL="http://localhost:8080"
PROM="http://localhost:9091"
WINDOW=60
MAX_5XX=1
MAX_P95=500
DB_STATEFULSET="postgres"
ANN="deploy.realworld.io"
MODE="deploy"
IMAGE=""
URL_EXPLICIT=false
PROM_EXPLICIT=false

log()  { printf '%s [deploy] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
warn() { log "AVISO: $*" >&2; }
fail() { log "ERRO: $*" >&2; exit 1; }

usage() {
  sed -n '3,25p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
}

# --- argumentos -----------------------------------------------------------------------
[[ $# -ge 1 ]] || usage
case "$1" in
  -h|--help) usage ;;
  --rollback) MODE="rollback" ;;
  -*) usage ;;
  *) IMAGE="$1" ;;
esac
shift
while getopts ":n:d:s:c:t:u:p:w:e:l:h" opt; do
  case "$opt" in
    n) NAMESPACE="$OPTARG" ;;
    d) DEPLOYMENT="$OPTARG" ;;
    s) SERVICE="$OPTARG" ;;
    c) CONTAINERS="$OPTARG" ;;
    t) TIMEOUT="$OPTARG" ;;
    u) URL="$OPTARG"; URL_EXPLICIT=true ;;
    p) PROM="$OPTARG"; PROM_EXPLICIT=true ;;
    w) WINDOW="$OPTARG" ;;
    e) MAX_5XX="$OPTARG" ;;
    l) MAX_P95="$OPTARG" ;;
    *) usage ;;
  esac
done

[[ "$WINDOW" =~ ^[0-9]+$ ]] || fail "-w espera segundos (número inteiro)"

for bin in kubectl curl; do
  command -v "$bin" >/dev/null || fail "$bin não encontrado no PATH"
done

ROOT="$(cd "$(dirname "$0")" && pwd)"
KUBECTL=(kubectl --namespace "$NAMESPACE")
FIRST_CONTAINER="${CONTAINERS%%,*}"

# --- funções ----------------------------------------------------------------------------
deploy_field() { "${KUBECTL[@]}" get deployment "$DEPLOYMENT" -o jsonpath="$1"; }
revision()     { deploy_field '{.metadata.annotations.deployment\.kubernetes\.io/revision}'; }
image_in_use() { deploy_field "{.spec.template.spec.containers[?(@.name=='$FIRST_CONTAINER')].image}"; }
annotation()   { deploy_field "{.metadata.annotations.${ANN//./\\.}/$1}"; }

# Uma linha por ReplicaSet do Deployment: "<revisão> <hash do template> <imagem>".
replicasets() {
  "${KUBECTL[@]}" get rs -l "$SELECTOR" \
    -o go-template="{{range .items}}{{index .metadata.annotations \"deployment.kubernetes.io/revision\"}} {{index .metadata.labels \"pod-template-hash\"}} {{range .spec.template.spec.containers}}{{if eq .name \"$FIRST_CONTAINER\"}}{{.image}}{{end}}{{end}}
{{end}}"
}

# Migrações já aplicadas, direto na tabela de controle do Prisma. Vazio se não der para
# consultar (sem StatefulSet, sem psql...): aí o passo do banco é só pulado, com aviso.
migrations() {
  # shellcheck disable=SC2016  # as variáveis são do shell DENTRO do container
  "${KUBECTL[@]}" exec "statefulset/$DB_STATEFULSET" -- sh -c \
    'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "select migration_name from _prisma_migrations where finished_at is not null order by finished_at"' \
    2>/dev/null || true
}

# Uma consulta instantânea no Prometheus; imprime só o valor (ou nada se não há série).
promq() {
  curl -fsS -G "$PROM/api/v1/query" --data-urlencode "query=$1" 2>/dev/null \
    | sed -n 's/.*"value":\[[^,]*,"\([^"]*\)".*/\1/p'
}

# Tráfego leve de leitura durante a janela, para a versão nova ter o que mostrar nas
# métricas mesmo sem usuários (num ambiente real, o tráfego orgânico já cumpre esse papel).
traffic() {
  local end=$((SECONDS + WINDOW))
  while (( SECONDS < end )); do
    for path in '/api/articles?limit=5' '/api/tags'; do
      curl -sS -o /dev/null -m 5 "$URL$path" 2>/dev/null || true
    done
    sleep 0.2
  done
}

# Hash do ReplicaSet da revisão atual do Deployment (é o que identifica os pods da versão).
current_hash() { replicasets | awk -v r="$(revision)" '$1 == r {print $2}'; }

# "rollout status" termina quando os pods novos estão prontos, mas os antigos ainda drenam por
# alguns segundos (preStop) e o kube-proxy demora a reprogramar o Service. Testar ou medir nesse
# intervalo misturaria as duas versões, e um rollback de uma versão com erro pegaria 500 dela.
# Espera o Service só ter endpoints prontos do ReplicaSet informado.
wait_switch() {
  local hash=$1 pods
  for _ in $(seq 1 30); do
    pods=$("${KUBECTL[@]}" get endpointslices -l "kubernetes.io/service-name=$SERVICE" \
      -o jsonpath='{range .items[*].endpoints[*]}{.conditions.ready}{" "}{.targetRef.name}{"\n"}{end}' 2>/dev/null \
      | awk '$1 == "true" {print $2}') || return 0
    if [[ -n "$pods" ]] && ! grep -qvE "^${DEPLOYMENT}-${hash}-" <<<"$pods"; then
      sleep 2  # folga para o kube-proxy aplicar a mudança
      return 0
    fi
    sleep 1
  done
  warn "service/$SERVICE ainda tem endpoints de outra versão depois de 30s; seguindo mesmo assim"
}

smoke() {
  if "$ROOT/smoke-test.sh" "$URL" >"$SMOKE_LOG" 2>&1; then
    SMOKE="ok"
  else
    # O último passo impresso pelo smoke test é o que falhou.
    SMOKE="FALHOU em: $(grep -E '^  [A-Z]' "$SMOKE_LOG" | tail -n1 | sed 's/^ *//; s/  .*//')"
  fi
}

diagnostics() {
  echo "--- pods do deployment (nome, fase, motivo de espera dos containers)"
  "${KUBECTL[@]}" get pods -l "$SELECTOR" -o go-template='{{range .items}}{{.metadata.name}}  {{.status.phase}}  {{range .status.initContainerStatuses}}{{if .state.waiting}}init/{{.name}}:{{.state.waiting.reason}} {{end}}{{end}}{{range .status.containerStatuses}}{{if .state.waiting}}{{.name}}:{{.state.waiting.reason}} {{end}}{{if not .ready}}(não pronto) {{end}}{{end}}
{{end}}'
  echo "--- últimos eventos de Warning no namespace"
  "${KUBECTL[@]}" get events --field-selector type=Warning --sort-by=.lastTimestamp 2>/dev/null | tail -n 10 || true
}

migrations_report() {
  [[ -n "$MIG_BEFORE" || -n "$MIG_AFTER" ]] || { warn "não consegui consultar _prisma_migrations; pulei a checagem do banco"; return; }
  local new
  new=$(comm -13 <(sort <<<"$MIG_BEFORE") <(sort <<<"$MIG_AFTER") | sed '/^$/d')
  if [[ -z "$new" ]]; then
    log "banco: nenhuma migração nova neste deploy"
  else
    log "banco: migrações aplicadas neste deploy: $(tr '\n' ' ' <<<"$new")"
  fi
  MIG_NEW="$new"
}

# --- pré-condições ----------------------------------------------------------------------
# Mostrar o contexto evita o clássico "deployei no cluster errado".
log "contexto: $(kubectl config current-context)  namespace: $NAMESPACE  deployment: $DEPLOYMENT"

"${KUBECTL[@]}" get deployment "$DEPLOYMENT" >/dev/null 2>&1 \
  || fail "deployment/$DEPLOYMENT não existe no namespace $NAMESPACE"

# Um rollout anterior ainda em andamento misturaria duas mudanças no mesmo deploy.
if ! "${KUBECTL[@]}" rollout status "deployment/$DEPLOYMENT" --timeout=5s >/dev/null 2>&1; then
  fail "deployment/$DEPLOYMENT tem um rollout em andamento ou com problema; resolva antes de publicar outro"
fi

# Seletor do Deployment, para achar pods e ReplicaSets dele.
# shellcheck disable=SC2016  # $k e $v são variáveis do go-template, não do shell
SELECTOR=$("${KUBECTL[@]}" get deployment "$DEPLOYMENT" \
  -o go-template='{{range $k, $v := .spec.selector.matchLabels}}{{$k}}={{$v}},{{end}}')
SELECTOR="${SELECTOR%,}"

PREV_REVISION=$(revision)
PREV_IMAGE=$(image_in_use)
LAST_GOOD_IMAGE=$(annotation last-good-image)
LAST_GOOD_REVISION=$(annotation last-good-revision)

log "no ar: revisão $PREV_REVISION, imagem $PREV_IMAGE"
if [[ -n "$LAST_GOOD_IMAGE" ]]; then
  log "última versão comprovada: $LAST_GOOD_IMAGE (revisão $LAST_GOOD_REVISION, em $(annotation last-good-at))"
else
  log "nenhuma versão comprovada registrada ainda (primeiro deploy pelo script)"
fi

if [[ "$MODE" == "rollback" ]]; then
  [[ -n "$LAST_GOOD_IMAGE" ]] || fail "não há versão comprovada para voltar; publique uma imagem explicitamente"
  IMAGE="$LAST_GOOD_IMAGE"
  log "modo rollback: alvo é a última versão comprovada, $IMAGE"
fi

# Imagem sem tag vira ":latest" implícito, o que tira a rastreabilidade do deploy.
[[ "${IMAGE##*/}" == *:* || "$IMAGE" == *@sha256:* ]] \
  || fail "informe a imagem com tag ou digest (ex.: repo/app:sha-1a2b3c4)"

if [[ "$PREV_IMAGE" == "$IMAGE" ]]; then
  log "a imagem pedida já está no ar, nada a fazer"
  exit 0
fi

# Quem foi passado explicitamente (-u/-p) tem que responder; o padrão, se não responde,
# só desliga aquela verificação com aviso. Assim o script serve tanto no CI (estrito)
# quanto num cluster onde não há Prometheus.
if [[ -n "$URL" ]] && ! curl -fsS -m 5 "$URL/healthz" >/dev/null 2>&1; then
  $URL_EXPLICIT && fail "API não responde em $URL/healthz"
  warn "API não responde em $URL; smoke test e tráfego de verificação desligados"
  URL=""
fi
if [[ -n "$PROM" ]] && ! curl -fsS -m 5 "$PROM/-/ready" >/dev/null 2>&1; then
  $PROM_EXPLICIT && fail "Prometheus não responde em $PROM/-/ready (scripts/monitoring-up.sh?)"
  warn "Prometheus não responde em $PROM; análise de métricas desligada"
  PROM=""
fi
[[ -n "$URL" || -n "$PROM" ]] || warn "sem URL nem Prometheus: a versão nova NÃO será verificada nem registrada como boa"

SMOKE_LOG=$(mktemp)
trap 'rm -f "$SMOKE_LOG"' EXIT
SMOKE="não executado"
MIG_NEW=""

# --- deploy -----------------------------------------------------------------------------
MIG_BEFORE=$(migrations)

# change-cause aparece no "kubectl rollout history": quem, quando, qual imagem.
MODE_TAG=""; [[ "$MODE" == rollback ]] && MODE_TAG=" (rollback)"
CAUSE="deploy.sh$MODE_TAG: $IMAGE por ${USER:-${USERNAME:-desconhecido}} em $(date -u +%Y-%m-%dT%H:%M:%SZ)"
"${KUBECTL[@]}" annotate deployment "$DEPLOYMENT" kubernetes.io/change-cause="$CAUSE" --overwrite >/dev/null

SET_ARGS=()
IFS=',' read -ra NAMES <<< "$CONTAINERS"
for name in "${NAMES[@]}"; do SET_ARGS+=("$name=$IMAGE"); done

log "publicando $IMAGE nos containers: $CONTAINERS"
"${KUBECTL[@]}" set image "deployment/$DEPLOYMENT" "${SET_ARGS[@]}"

log "aguardando rollout (timeout $TIMEOUT)..."
ROLLOUT_OK=false
if "${KUBECTL[@]}" rollout status "deployment/$DEPLOYMENT" --timeout="$TIMEOUT"; then
  ROLLOUT_OK=true
fi
MIG_AFTER=$(migrations)
NEW_REVISION=$(revision)

# --- verificação pós-rollout ------------------------------------------------------------
VERIFIED=false   # passou em tudo que dava para verificar
FAILED=false     # reprovou em algo
if $ROLLOUT_OK; then
  log "rollout concluído: revisão $NEW_REVISION com $IMAGE. Verificando a versão nova em serviço."
  migrations_report

  # Só os pods do ReplicaSet novo entram na conta: é a versão nova que está em julgamento.
  NEW_HASH=$(current_hash)
  POD_RE="${DEPLOYMENT}-${NEW_HASH}-.*"
  wait_switch "$NEW_HASH"

  [[ -n "$URL" ]] && smoke

  if [[ -n "$PROM" ]]; then
    log "janela de ${WINDOW}s medindo pods $POD_RE no Prometheus${URL:+ (com tráfego de leitura em $URL)}"
    if [[ -n "$URL" ]]; then traffic; else sleep "$WINDOW"; fi
    SEL="pod=~\"$POD_RE\""
    TOTAL=$(promq "sum(increase(http_requests_total{$SEL}[${WINDOW}s]))")
    ERRORS=$(promq "sum(increase(http_requests_total{$SEL,status_code=~\"5..\"}[${WINDOW}s]))")
    P95=$(promq "histogram_quantile(0.95, sum by (le) (rate(http_request_duration_seconds_bucket{$SEL}[${WINDOW}s])))")
    read -r SAMPLES PCT_5XX <<<"$(awk -v t="${TOTAL:-0}" -v e="${ERRORS:-0}" \
      'BEGIN { printf "%d %.2f\n", t + 0.5, (t > 0) ? e * 100 / t : 0 }')"
    # Sem amostra o histograma devolve NaN; fica "NaN" e reprova: não se aprova o que não se mediu.
    if [[ -z "$P95" || "$P95" == NaN ]]; then P95_MS="NaN"; else P95_MS=$(awk -v p="$P95" 'BEGIN { printf "%d\n", p * 1000 + 0.5 }'); fi
  fi

  echo "--- verificação da versão nova (revisão $NEW_REVISION, $IMAGE)"
  printf '  %-28s %s\n' "smoke test" "$SMOKE"
  if [[ -n "$PROM" ]]; then
    if (( SAMPLES < 20 )); then
      printf '  %-28s %s\n' "amostra" "$SAMPLES requisições em ${WINDOW}s: insuficiente para julgar"
    else
      V5=$(awk -v a="$PCT_5XX" -v m="$MAX_5XX" 'BEGIN { print (a + 0 > m + 0) ? "ACIMA DO LIMITE" : "ok" }')
      if [[ "$P95_MS" == NaN ]]; then VP="ACIMA DO LIMITE"; else
        VP=$(awk -v a="$P95_MS" -v m="$MAX_P95" 'BEGIN { print (a + 0 > m + 0) ? "ACIMA DO LIMITE" : "ok" }')
      fi
      printf '  %-28s %s\n' "taxa de 5xx" "${PCT_5XX}% (limite ${MAX_5XX}%)  $V5"
      printf '  %-28s %s\n' "p95" "${P95_MS} ms (limite ${MAX_P95} ms)  $VP"
      printf '  %-28s %s\n' "amostra" "$SAMPLES requisições em ${WINDOW}s"
      [[ "$V5" == ok && "$VP" == ok ]] && VERIFIED=true || FAILED=true
    fi
  fi
  [[ "$SMOKE" == ok ]] && { [[ -n "$PROM" ]] || VERIFIED=true; }
  [[ "$SMOKE" == FALHOU* ]] && { FAILED=true; VERIFIED=false; }
else
  log "FALHA: o rollout não terminou em $TIMEOUT."
  FAILED=true
fi

# --- aprovado ---------------------------------------------------------------------------
if $ROLLOUT_OK && ! $FAILED; then
  if $VERIFIED; then
    "${KUBECTL[@]}" annotate deployment "$DEPLOYMENT" --overwrite \
      "$ANN/last-good-image=$IMAGE" "$ANN/last-good-revision=$NEW_REVISION" \
      "$ANN/last-good-at=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >/dev/null
    log "SUCESSO: revisão $NEW_REVISION no ar com $IMAGE, verificada e registrada como última versão boa"
  else
    warn "revisão $NEW_REVISION está no ar com $IMAGE, mas sem verificação suficiente: NÃO foi registrada como boa"
  fi
  "${KUBECTL[@]}" get pods -l "$SELECTOR" -o wide
  exit 0
fi

# --- reprovado: diagnóstico -------------------------------------------------------------
log "REPROVADO. Coletando diagnóstico antes do rollback."
$ROLLOUT_OK || diagnostics
[[ "$SMOKE" == FALHOU* ]] && { echo "--- smoke test"; cat "$SMOKE_LOG"; }
$ROLLOUT_OK || migrations_report
if [[ -n "$MIG_NEW" ]]; then
  warn "as migrações acima continuam aplicadas: a versão restaurada vai rodar sobre o schema novo."
  warn "isso só é seguro se elas forem compatíveis com a versão anterior (expand/contract); senão, o rollback do schema é manual."
fi

# --- rollback ---------------------------------------------------------------------------
# Alvo: a última versão comprovada. Por revisão quando o ReplicaSet dela ainda existe (volta o
# template inteiro: imagem, config, probes), por imagem quando o histórico já girou. O
# ReplicaSet é procurado pela imagem, não pelo número da revisão: um "rollout undo" reaproveita
# o ReplicaSet antigo e o renumera, então o número anotado envelhece; a imagem não.
# Sem versão comprovada (ou se a comprovada é justamente a que falhou), resta a revisão anterior.
if [[ -n "$LAST_GOOD_IMAGE" && "$LAST_GOOD_IMAGE" != "$IMAGE" ]]; then
  GOOD_REVISION=$(replicasets | awk -v i="$LAST_GOOD_IMAGE" '$3 == i && $1 + 0 > best + 0 {best = $1} END {print best}')
  if [[ -n "$GOOD_REVISION" ]]; then
    log "rollback para a última versão comprovada: revisão $GOOD_REVISION ($LAST_GOOD_IMAGE)"
    "${KUBECTL[@]}" rollout undo "deployment/$DEPLOYMENT" --to-revision="$GOOD_REVISION"
  else
    log "rollback para a última versão comprovada: $LAST_GOOD_IMAGE (revisão fora do histórico; publicando a imagem)"
    SET_ARGS=()
    for name in "${NAMES[@]}"; do SET_ARGS+=("$name=$LAST_GOOD_IMAGE"); done
    "${KUBECTL[@]}" set image "deployment/$DEPLOYMENT" "${SET_ARGS[@]}"
  fi
  TARGET="$LAST_GOOD_IMAGE"
else
  warn "sem versão comprovada para voltar; usando a revisão anterior, $PREV_REVISION ($PREV_IMAGE), sem garantia de que ela era boa"
  "${KUBECTL[@]}" rollout undo "deployment/$DEPLOYMENT" --to-revision="$PREV_REVISION"
  TARGET="$PREV_IMAGE"
fi

if "${KUBECTL[@]}" rollout status "deployment/$DEPLOYMENT" --timeout="$TIMEOUT"; then
  if [[ -n "$URL" ]]; then
    wait_switch "$(current_hash)"
    smoke
    [[ "$SMOKE" == ok ]] || { log "ROLLBACK FALHOU: $TARGET voltou mas o smoke test reprovou: $SMOKE"; exit 3; }
  fi
  log "ROLLBACK OK: $TARGET voltou e está saudável. O deploy de $IMAGE foi revertido."
  exit 2
fi

log "ROLLBACK FALHOU: o deployment/$DEPLOYMENT não voltou a ficar saudável. Intervenção manual necessária."
exit 3
