#!/usr/bin/env bash
#
# Sobe o ambiente Kubernetes local: cluster kind, metrics-server (necessário para o HPA)
# e a aplicação (Postgres + API).
#
#   scripts/kind-up.sh           # usa a imagem publicada no GHCR (tag definida no kustomization)
#   scripts/kind-up.sh --local   # builda a imagem local e carrega direto nos nós do kind
#
# Idempotente: rodar de novo não recria o cluster nem duplica configuração.

set -Eeuo pipefail

CLUSTER="realworld"
NAMESPACE="realworld"
METRICS_SERVER_VERSION="v0.9.0"
LOCAL_IMAGE="realworld-api:local"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OVERLAY="$ROOT/k8s/overlays/kind"

log() { printf '\n==> %s\n' "$*"; }

USE_LOCAL=false
[[ "${1:-}" == "--local" ]] && USE_LOCAL=true

for bin in docker kind kubectl; do
  command -v "$bin" >/dev/null || { echo "ERRO: $bin não encontrado no PATH" >&2; exit 1; }
done

# --- cluster ---------------------------------------------------------------------------
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  log "cluster kind '$CLUSTER' já existe"
else
  log "criando cluster kind '$CLUSTER' (1 control-plane + 2 workers)"
  kind create cluster --config "$ROOT/k8s/kind-cluster.yaml" --wait 180s
fi
kubectl config use-context "kind-$CLUSTER" >/dev/null

# --- metrics-server ----------------------------------------------------------------------
# Sem ele o HPA fica em <unknown>. No kind o kubelet usa certificado autoassinado,
# por isso o --kubelet-insecure-tls (aceitável só em cluster local).
log "instalando metrics-server $METRICS_SERVER_VERSION"
kubectl apply -f "https://github.com/kubernetes-sigs/metrics-server/releases/download/$METRICS_SERVER_VERSION/components.yaml" >/dev/null
if ! kubectl -n kube-system get deployment metrics-server -o jsonpath='{.spec.template.spec.containers[0].args}' | grep -q kubelet-insecure-tls; then
  kubectl -n kube-system patch deployment metrics-server --type=json \
    -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]' >/dev/null
fi

# --- segredos locais ---------------------------------------------------------------------
# Gerados aleatoriamente na primeira execução e nunca versionados (.gitignore).
if [[ ! -f "$OVERLAY/secrets.env" ]]; then
  log "gerando $OVERLAY/secrets.env com valores aleatórios"
  rand() { od -An -N24 -tx1 /dev/urandom | tr -d ' \n'; }
  printf 'POSTGRES_PASSWORD=%s\nJWT_SECRET=%s\n' "$(rand)" "$(rand)" > "$OVERLAY/secrets.env"
fi

# --- imagem local (opcional) -------------------------------------------------------------
if $USE_LOCAL; then
  log "buildando $LOCAL_IMAGE e carregando nos nós do kind"
  docker build -t "$LOCAL_IMAGE" "$ROOT"
  kind load docker-image "$LOCAL_IMAGE" --name "$CLUSTER"
fi

# --- aplicação ---------------------------------------------------------------------------
log "aplicando manifests (kustomize: k8s/overlays/kind)"
kubectl apply -k "$OVERLAY"

if $USE_LOCAL; then
  kubectl -n "$NAMESPACE" set image deployment/api api="$LOCAL_IMAGE" migrate="$LOCAL_IMAGE"
fi

log "aguardando Postgres e API ficarem prontos"
kubectl -n "$NAMESPACE" rollout status statefulset/postgres --timeout=180s
kubectl -n "$NAMESPACE" rollout status deployment/api --timeout=300s
kubectl -n kube-system rollout status deployment/metrics-server --timeout=120s

log "estado final"
kubectl -n "$NAMESPACE" get pods -o wide
kubectl -n "$NAMESPACE" get svc,hpa,pdb

cat <<EOF

API disponível em http://localhost:8080
  curl http://localhost:8080/api/tags
  scripts/smoke-test.sh http://localhost:8080
EOF
