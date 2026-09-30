#!/usr/bin/env bash
#
# Teste de fumaça da API: saúde, cadastro, criação e leitura de artigo, e métricas.
# Usado no CI (Compose e kind) e na demo. Só depende de curl.
#
#   scripts/smoke-test.sh [url-base]      # padrão: http://localhost:3000

set -Eeuo pipefail

BASE="${1:-http://localhost:3000}"
USERNAME="smoke$(date +%s)$RANDOM"
TITLE="Smoke test $USERNAME"

step() { printf '  %-45s' "$1"; }
ok()   { echo "ok"; }
die()  { echo "FALHOU"; exit 1; }

# A resposta vai para uma variável antes do grep: com pipefail, "curl | grep -q" falharia
# quando o grep encerra cedo e o curl recebe SIGPIPE, mesmo com o texto encontrado.

echo "==> smoke test em $BASE"

step "GET /healthz"
curl -fsS "$BASE/healthz" >/dev/null || die
ok

step "GET /readyz (API + banco)"
curl -fsS "$BASE/readyz" >/dev/null || die
ok

step "POST /api/users (cadastro)"
TOKEN=$(curl -fsS -X POST "$BASE/api/users" -H 'Content-Type: application/json' \
  -d "{\"user\":{\"username\":\"$USERNAME\",\"email\":\"$USERNAME@example.com\",\"password\":\"Demo-senha-123\"}}" \
  | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
[[ -n "$TOKEN" ]] || die
ok

step "POST /api/articles (autenticado)"
curl -fsS -X POST "$BASE/api/articles" -H 'Content-Type: application/json' -H "Authorization: Token $TOKEN" \
  -d "{\"article\":{\"title\":\"$TITLE\",\"description\":\"criado pelo smoke test\",\"body\":\"ok\",\"tagList\":[\"devops\",\"smoke\"]}}" \
  >/dev/null || die
ok

# Autenticado: a listagem anônima só traz artigos de autores "demo"; os do próprio usuário
# entram quando a requisição leva o token.
step "GET /api/articles contém o artigo criado"
body=$(curl -fsS -H "Authorization: Token $TOKEN" "$BASE/api/articles?author=$USERNAME") || die
grep -q "$TITLE" <<<"$body" || die
ok

step "GET /api/tags"
body=$(curl -fsS "$BASE/api/tags") || die
grep -q '"tags"' <<<"$body" || die
ok

step "GET /metrics expõe http_requests_total"
body=$(curl -fsS "$BASE/metrics") || die
grep -q '^http_requests_total' <<<"$body" || die
ok

echo "==> tudo certo"
