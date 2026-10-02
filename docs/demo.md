# Roteiro da demo (30 min)

Comandos na ordem em que aparecem na apresentação. Tudo em bash (Git Bash no Windows), na raiz do repositório.

## Antes da chamada (15 min antes)

```bash
cp -n .env.example .env
docker compose --profile observability up -d --build   # sobe tudo e aquece o cache
scripts/kind-up.sh                                     # cluster pronto antes de começar
scripts/monitoring-up.sh                               # Prometheus no kind + port-forward: painel de réplicas no Grafana
scripts/smoke-test.sh http://localhost:3000            # gera tráfego para o dashboard
```

Abas abertas: README no GitHub, aba Actions (último run do CI e do CD), pacote no GHCR,
Grafana (http://localhost:3001) com o dashboard RealWorld API, a API respondendo
(http://localhost:3000/api/articles) e dois terminais Git Bash.

A aplicação não tem interface: "aplicação rodando" é o JSON no navegador e o smoke test
criando usuário e artigo ao vivo.

## 1. Visão geral e decisões (3 min)

README no GitHub: diagrama e tabela de entregas. Três decisões para destacar:

1. uma imagem para API e migração (schema e código nunca divergem);
2. liveness não checa o banco, readiness checa;
3. o CI testa o próprio script de deploy, inclusive o rollback.

## 2. Docker (4 min)

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

## 3. Kubernetes (7 min)

```bash
kubectl get nodes
kubectl -n realworld get pods -o wide             # réplicas em workers diferentes
kubectl -n realworld get deploy,sts,svc,hpa,pdb,netpol
kubectl -n realworld describe deploy api | sed -n '/Liveness/,/Environment/p'
kubectl -n realworld logs deploy/api -c migrate   # initContainer de migração
curl -s localhost:8080/readyz; echo

# HPA: em outro terminal. No Grafana, o painel "Réplicas da API prontas no kind" acompanha.
scripts/load-test.sh 8 150
kubectl -n realworld get hpa api --watch

# Readiness na prática: derrubar o banco tira os pods do Service sem reiniciá-los
kubectl -n realworld scale sts postgres --replicas=0
kubectl -n realworld get pods -w                  # READY 0/1, RESTARTS continua 0
kubectl -n realworld scale sts postgres --replicas=1
```

## 4. Pipeline (5 min)

No GitHub, aba Actions:

- run de CI de um PR: os 4 jobs, resumo com tamanho da imagem, Trivy e contagem do lint herdado;
- job **Kubernetes e2e**: passos "deploy.sh publica uma versão nova" e "faz rollback de uma imagem quebrada";
- run de CD: `CI` como pré-requisito, resumo com tags, digest e comando de verificação do cosign;
- pacote no GHCR com as tags `sha-…`, `main`, `latest`.

Se der tempo, abrir um PR ao vivo (uma linha no README) e mostrar os checks rodando.

## 5. Observabilidade (4 min)

Grafana → dashboard **RealWorld API**:

```bash
scripts/error-demo.sh          # tráfego normal → banco fora (500, /readyz 503) → banco de volta
scripts/error-demo.sh --kind   # a mesma coisa no cluster: o painel de réplicas prontas cai e volta
```

O script mostra o código HTTP de cada requisição no terminal (200 → 500 → 200) e religa o
banco sozinho, inclusive se for interrompido.

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

## 7. Produção real e perguntas (3 min)

Tabela "Em produção, o que eu faria diferente (Azure)" do README.

## Depois

```bash
scripts/monitoring-up.sh --stop
docker compose --profile observability down -v
scripts/kind-down.sh
```
