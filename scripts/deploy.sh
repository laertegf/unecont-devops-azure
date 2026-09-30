#!/usr/bin/env bash
#
# deploy.sh — publica uma nova imagem num Deployment do Kubernetes, espera o rollout
# terminar e, se der errado, faz rollback automático para a revisão que estava no ar.
#
# Uso:
#   scripts/deploy.sh <imagem> [-n namespace] [-d deployment] [-c containers] [-t timeout]
#
# Exemplos:
#   scripts/deploy.sh ghcr.io/laertegf/unecont-devops-azure:sha-1a2b3c4
#   scripts/deploy.sh ghcr.io/laertegf/unecont-devops-azure:nao-existe -t 60s   # força falha e rollback
#
# Códigos de saída (pensados para quem chama o script, ex.: um pipeline):
#   0  deploy concluído (ou nada a fazer: a imagem já era essa)
#   1  erro de uso ou pré-condição (sem kubectl, Deployment inexistente...)
#   2  rollout falhou, rollback feito e a versão anterior está saudável
#   3  rollout falhou e o rollback também falhou: precisa de gente olhando AGORA
#
# Decisões, e por quê:
#
# - Bash + kubectl, sem dependências extras (jq, yq, helm). Roda igual no runner do
#   GitHub Actions, num bastion ou no Git Bash do Windows.
#
# - O rollback volta para a revisão ANOTADA ANTES do deploy (--to-revision), não para
#   "a anterior". Se alguém fizer outro deploy no meio, um "rollout undo" simples voltaria
#   para a versão errada.
#
# - O "kubectl rollout status" é quem decide sucesso ou falha. Ele só termina quando as
#   réplicas novas passam na readinessProbe. Ou seja: as probes do Deployment são o teste
#   de saúde do deploy, e o script não duplica essa lógica com curl.
#
# - Timeout explícito: sem ele, uma imagem que não existe (ImagePullBackOff) deixaria o
#   script pendurado até o progressDeadlineSeconds (10 min por padrão).
#
# - Diagnóstico ANTES do rollback: depois do undo os pods com problema são removidos e
#   o motivo da falha (ImagePullBackOff, CrashLoopBackOff, probe falhando) se perde.
#
# - Atualiza também o initContainer "migrate": API e migração vêm do mesmo artefato,
#   então precisam andar juntos. A lista de containers é configurável com -c.
#
# - O Deployment usa maxUnavailable: 0. Enquanto a versão nova não fica pronta, as
#   réplicas antigas continuam atendendo, e um deploy ruim não derruba o serviço.

set -Eeuo pipefail

NAMESPACE="realworld"
DEPLOYMENT="api"
CONTAINERS="api,migrate"
TIMEOUT="120s"
IMAGE=""

log()  { printf '%s [deploy] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
fail() { log "ERRO: $*" >&2; exit 1; }

usage() {
  sed -n '3,12p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
}

# --- argumentos -----------------------------------------------------------------------
[[ $# -ge 1 ]] || usage
case "$1" in -h|--help) usage ;; esac
IMAGE="$1"; shift
while getopts ":n:d:c:t:h" opt; do
  case "$opt" in
    n) NAMESPACE="$OPTARG" ;;
    d) DEPLOYMENT="$OPTARG" ;;
    c) CONTAINERS="$OPTARG" ;;
    t) TIMEOUT="$OPTARG" ;;
    *) usage ;;
  esac
done

# Imagem sem tag vira ":latest" implícito, o que tira a rastreabilidade do deploy.
[[ "${IMAGE##*/}" == *:* || "$IMAGE" == *@sha256:* ]] \
  || fail "informe a imagem com tag ou digest (ex.: repo/app:sha-1a2b3c4)"

command -v kubectl >/dev/null || fail "kubectl não encontrado no PATH"

KUBECTL=(kubectl --namespace "$NAMESPACE")

# --- pré-condições ----------------------------------------------------------------------
# Mostrar o contexto evita o clássico "deployei no cluster errado".
log "contexto: $(kubectl config current-context)  namespace: $NAMESPACE  deployment: $DEPLOYMENT"

"${KUBECTL[@]}" get deployment "$DEPLOYMENT" >/dev/null 2>&1 \
  || fail "deployment/$DEPLOYMENT não existe no namespace $NAMESPACE"

# Um rollout anterior ainda em andamento misturaria duas mudanças no mesmo deploy.
if ! "${KUBECTL[@]}" rollout status "deployment/$DEPLOYMENT" --timeout=5s >/dev/null 2>&1; then
  fail "deployment/$DEPLOYMENT tem um rollout em andamento ou com problema; resolva antes de publicar outro"
fi

PREV_REVISION=$("${KUBECTL[@]}" get deployment "$DEPLOYMENT" \
  -o jsonpath='{.metadata.annotations.deployment\.kubernetes\.io/revision}')
FIRST_CONTAINER="${CONTAINERS%%,*}"
PREV_IMAGE=$("${KUBECTL[@]}" get deployment "$DEPLOYMENT" \
  -o jsonpath="{.spec.template.spec.containers[?(@.name=='$FIRST_CONTAINER')].image}")

log "no ar: revisão $PREV_REVISION, imagem $PREV_IMAGE"

if [[ "$PREV_IMAGE" == "$IMAGE" ]]; then
  log "a imagem pedida já está no ar, nada a fazer"
  exit 0
fi

# Seletor do Deployment, para achar os pods dele no diagnóstico.
# shellcheck disable=SC2016  # $k e $v são variáveis do go-template, não do shell
SELECTOR=$("${KUBECTL[@]}" get deployment "$DEPLOYMENT" \
  -o go-template='{{range $k, $v := .spec.selector.matchLabels}}{{$k}}={{$v}},{{end}}')
SELECTOR="${SELECTOR%,}"

# --- deploy -----------------------------------------------------------------------------
# change-cause aparece no "kubectl rollout history": quem, quando, qual imagem.
CAUSE="deploy.sh: $IMAGE por ${USER:-${USERNAME:-desconhecido}} em $(date -u +%Y-%m-%dT%H:%M:%SZ)"
"${KUBECTL[@]}" annotate deployment "$DEPLOYMENT" kubernetes.io/change-cause="$CAUSE" --overwrite >/dev/null

SET_ARGS=()
IFS=',' read -ra NAMES <<< "$CONTAINERS"
for name in "${NAMES[@]}"; do SET_ARGS+=("$name=$IMAGE"); done

log "publicando $IMAGE nos containers: $CONTAINERS"
"${KUBECTL[@]}" set image "deployment/$DEPLOYMENT" "${SET_ARGS[@]}"

log "aguardando rollout (timeout $TIMEOUT)..."
if "${KUBECTL[@]}" rollout status "deployment/$DEPLOYMENT" --timeout="$TIMEOUT"; then
  NEW_REVISION=$("${KUBECTL[@]}" get deployment "$DEPLOYMENT" \
    -o jsonpath='{.metadata.annotations.deployment\.kubernetes\.io/revision}')
  log "SUCESSO: revisão $NEW_REVISION no ar com $IMAGE"
  "${KUBECTL[@]}" get pods -l "$SELECTOR" -o wide
  exit 0
fi

# --- falhou: diagnóstico ----------------------------------------------------------------
log "FALHA: o rollout não terminou em $TIMEOUT. Coletando diagnóstico antes do rollback."

echo "--- pods do deployment (nome, fase, motivo de espera dos containers)"
"${KUBECTL[@]}" get pods -l "$SELECTOR" -o go-template='{{range .items}}{{.metadata.name}}  {{.status.phase}}  {{range .status.initContainerStatuses}}{{if .state.waiting}}init/{{.name}}:{{.state.waiting.reason}} {{end}}{{end}}{{range .status.containerStatuses}}{{if .state.waiting}}{{.name}}:{{.state.waiting.reason}} {{end}}{{if not .ready}}(não pronto) {{end}}{{end}}
{{end}}'

echo "--- últimos eventos de Warning no namespace"
"${KUBECTL[@]}" get events --field-selector type=Warning --sort-by=.lastTimestamp 2>/dev/null | tail -n 10 || true

# --- rollback ---------------------------------------------------------------------------
log "rollback para a revisão $PREV_REVISION ($PREV_IMAGE)"
"${KUBECTL[@]}" rollout undo "deployment/$DEPLOYMENT" --to-revision="$PREV_REVISION"

if "${KUBECTL[@]}" rollout status "deployment/$DEPLOYMENT" --timeout="$TIMEOUT"; then
  log "ROLLBACK OK: $PREV_IMAGE voltou e está saudável. O deploy de $IMAGE foi revertido."
  exit 2
fi

log "ROLLBACK FALHOU: o deployment/$DEPLOYMENT não voltou a ficar saudável. Intervenção manual necessária."
exit 3
