# Roteiro da demo (40 min)

Comandos na ordem em que aparecem na apresentação. Tudo em bash (Git Bash no Windows), na raiz do repositório.

## Antes da chamada (15 min antes)

```bash
cp -n .env.example .env
docker compose --profile observability up -d --build   # sobe tudo e aquece o cache
scripts/kind-up.sh                                     # cluster pronto antes de começar
scripts/smoke-test.sh http://localhost:3000            # gera tráfego para o dashboard
```

Abas abertas: README no GitHub, aba Actions (último run do CI e do CD), pacote no GHCR,
Grafana (http://localhost:3001) com o dashboard RealWorld API, terminal.

## 1. Visão geral e decisões (5 min)

README no GitHub: diagrama e tabela de entregas. Três decisões para destacar:

1. uma imagem para API e migração (schema e código nunca divergem);
2. liveness não checa o banco, readiness checa;
3. o CI testa o próprio script de deploy, inclusive o rollback.

## 2. Docker (7 min)

```bash
# Dockerfile: estágios build → prod-deps → runtime
docker image ls realworld-api                     # tamanho da imagem
docker history realworld-api:local | head         # camadas
docker compose ps                                 # migrate "Exited (0)", api "healthy"
docker compose exec api id                        # uid=1000(node), não-root
docker compose logs migrate                       # migrations aplicadas
scripts/smoke-test.sh http://localhost:3000
curl -s localhost:3000/api/articles | head -c 300; echo
```

## 3. Kubernetes (8 min)

```bash
kubectl get nodes
kubectl -n realworld get pods -o wide             # réplicas em workers diferentes
kubectl -n realworld get deploy,sts,svc,hpa,pdb,netpol
kubectl -n realworld describe deploy api | sed -n '/Liveness/,/Environment/p'
kubectl -n realworld logs deploy/api -c migrate   # initContainer de migração
curl -s localhost:8080/readyz; echo

# HPA: em outro terminal
scripts/load-test.sh 8 150
kubectl -n realworld get hpa api --watch

# Readiness na prática: derrubar o banco tira os pods do Service sem reiniciá-los
kubectl -n realworld scale sts postgres --replicas=0
kubectl -n realworld get pods -w                  # READY 0/1, RESTARTS continua 0
kubectl -n realworld scale sts postgres --replicas=1
```

## 4. Pipeline (7 min)

No GitHub, aba Actions:

- run de CI de um PR: os 4 jobs, resumo com tamanho da imagem, Trivy e contagem do lint herdado;
- job **Kubernetes e2e**: passos "deploy.sh publica uma versão nova" e "faz rollback de uma imagem quebrada";
- run de CD: `CI` como pré-requisito, resumo com tags, digest e comando de verificação do cosign;
- pacote no GHCR com as tags `sha-…`, `main`, `latest`.

Se der tempo, abrir um PR ao vivo (uma linha no README) e mostrar os checks rodando.

## 5. Observabilidade (6 min)

Grafana → dashboard **RealWorld API**:

```bash
for i in $(seq 1 200); do curl -s -o /dev/null localhost:3000/api/articles; done   # tráfego
docker compose stop postgres
for i in $(seq 1 20); do curl -s -o /dev/null localhost:3000/api/tags; done         # gera 500
docker compose start postgres
```

- painéis de taxa de 5xx e logs de erro subindo;
- Explore → Loki: `{service="api"} | json | status >= 500`;
- Explore → Prometheus: `sum by (route, status_code) (rate(http_requests_total[1m]))`.

## 6. Script (4 min)

```bash
kubectl -n realworld rollout history deploy/api
scripts/deploy.sh ghcr.io/laertegf/unecont-devops-azure:sha-<commit>        # sucesso
scripts/deploy.sh ghcr.io/laertegf/unecont-devops-azure:nao-existe -t 45s   # ImagePullBackOff → rollback
echo $?                                                                     # 2
kubectl -n realworld rollout history deploy/api
```

## 7. Produção real (3 min)

Tabela "Em produção, o que eu faria diferente (Azure)" do README.

## Depois

```bash
docker compose --profile observability down -v
scripts/kind-down.sh
```
