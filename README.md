# RealWorld API: infraestrutura DevOps

[![CI](https://github.com/laertegf/unecont-devops-azure/actions/workflows/ci.yml/badge.svg)](https://github.com/laertegf/unecont-devops-azure/actions/workflows/ci.yml)
[![CD](https://github.com/laertegf/unecont-devops-azure/actions/workflows/cd.yml/badge.svg)](https://github.com/laertegf/unecont-devops-azure/actions/workflows/cd.yml)

Containerização, Kubernetes local, pipeline CI/CD, observabilidade e automação para uma API REST
em Node.js. A aplicação é a [RealWorld Node/Express/Prisma](https://github.com/gothinkster/node-express-realworld-example-app)
(Express + Prisma + PostgreSQL), usada como base. O foco aqui é a infraestrutura; as mudanças na
aplicação foram só as necessárias para ela ser operável (ver [Mudanças na aplicação](#mudanças-na-aplicação)).

Tudo roda local ou em serviço gratuito: Docker, kind, GitHub Actions e GHCR.

## Visão geral

```mermaid
flowchart LR
  dev[PR / push na main] --> gha

  subgraph gha[GitHub Actions]
    ci[CI: build, testes com Postgres,<br/>lint, hadolint, shellcheck,<br/>kubeconform, Trivy,<br/>e2e no Compose e no kind]
    cd[CD: build + push<br/>SBOM, proveniência, cosign]
    ci --> cd
  end

  cd --> ghcr[(GHCR<br/>ghcr.io/laertegf/unecont-devops-azure)]

  subgraph local[Máquina local]
    subgraph compose[Docker Compose]
      pg[(Postgres)] --> mig[migrate] --> api[API]
      alloy[Alloy] -->|logs| loki[Loki]
      prom[Prometheus] -->|scrape /metrics| api
      graf[Grafana] --> loki & prom
    end
    subgraph kind[kind: 1 control-plane + 2 workers]
      dep[Deployment api<br/>2..6 réplicas, HPA, PDB] --> sts[(StatefulSet postgres)]
    end
  end

  ghcr --> kind
  ghcr -.-> compose
```

| Entrega | Onde | Como rodar |
|---|---|---|
| 1. Docker | [`Dockerfile`](Dockerfile), [`docker-compose.yml`](docker-compose.yml) | `docker compose up -d --build` |
| 2. Kubernetes local | [`k8s/`](k8s) (kustomize) | `scripts/kind-up.sh` |
| 3. CI/CD | [`.github/workflows/`](.github/workflows) | abrir um PR / push na `main` |
| 4. Observabilidade | [`observability/`](observability) | `docker compose --profile observability up -d` |
| 5. Script | [`scripts/deploy.sh`](scripts/deploy.sh) | `scripts/deploy.sh <imagem>` |

## Pré-requisitos

Docker Desktop, [kind](https://kind.sigs.k8s.io), kubectl e um shell bash (no Windows, o Git Bash).

```bash
cp .env.example .env    # troque as senhas; o .env não vai para o git
```

## 1. Docker

**Dockerfile** com build em 3 estágios sobre `node:22-slim`:

| Estágio | O que faz | Vai para a imagem final? |
|---|---|---|
| `build` | `npm ci` completo, `prisma generate`, build com Nx/esbuild | não |
| `prod-deps` | só dependências de produção + CLI do Prisma | só `node_modules` |
| `runtime` | código compilado + dependências | sim |

Decisões:

- **Usuário não-root** (`node`, uid 1000), com os arquivos da aplicação pertencendo ao root: o processo
  não consegue alterar o próprio código. Combina com `read_only: true` no Compose e `readOnlyRootFilesystem` no Kubernetes.
- **Mesma base em todos os estágios (Debian slim).** O Prisma escolhe o engine nativo pela libc/OpenSSL no
  `prisma generate`; buildar em uma base e rodar em outra é a causa clássica de "engine not found".
- **Uma imagem, dois usos**: a mesma imagem roda a API e o `prisma migrate deploy`. Schema e código nunca ficam fora de sincronia.
- **Configuração só por variável de ambiente** (`DATABASE_URL`, `JWT_SECRET`, `PORT`, `LOG_LEVEL`...), sem segredo com valor padrão.
- **Contexto de build mínimo** (`.dockerignore` em modo allowlist): `.env`, `.git` e testes nunca entram na imagem.
- `HEALTHCHECK` na imagem para o Docker/Compose; no Kubernetes valem as probes.

**docker-compose.yml**: a ordem de subida é garantida por healthcheck, não por `sleep`:

```
postgres (healthy) → migrate (termina com sucesso) → api (healthy)
```

```bash
docker compose up -d --build
docker compose ps
scripts/smoke-test.sh http://localhost:3000   # cadastro, artigo, tags, métricas
```

## 2. Kubernetes local (kind)

```bash
scripts/kind-up.sh            # usa a imagem publicada no GHCR
scripts/kind-up.sh --local    # ou builda localmente e carrega no kind
```

Cluster com 1 control-plane e 2 workers ([`k8s/kind-cluster.yaml`](k8s/kind-cluster.yaml)); a API fica em
`http://localhost:8080` via NodePort. O script instala o metrics-server (necessário para o HPA), gera os
segredos locais e aplica o overlay `k8s/overlays/kind`.

| Recurso | Detalhes |
|---|---|
| Deployment `api` | 2 réplicas iniciais; rolling update com `maxUnavailable: 0`; espalhado entre nós (`topologySpreadConstraints`) |
| Probes | **startup** `/healthz` (até 60s para subir) · **liveness** `/healthz` (processo vivo, não olha o banco) · **readiness** `/readyz` (checa o banco) |
| Migração | `initContainer` com `prisma migrate deploy` (idempotente, advisory lock no Postgres) |
| ConfigMap / Secret | gerados pelo kustomize com hash no nome: mudar config dispara rollout sozinho. Segredos em arquivo local fora do git |
| HPA | CPU 60% do request, 2 a 6 réplicas; sobe rápido e desce devagar (`behavior`) |
| PDB | `minAvailable: 1` durante drain de nó |
| Segurança | namespace com Pod Security `restricted`, não-root, rootfs read-only, sem capabilities, seccomp, sem token de ServiceAccount |
| NetworkPolicy | Postgres só aceita conexão dos pods da API |
| Graceful shutdown | `preStop` de 5s + a app trata SIGTERM (readiness 503, fecha conexões, encerra) |

Por que **liveness não checa o banco**: se o Postgres cai, reiniciar todos os pods não resolve nada e ainda
soma um restart em massa ao incidente. Quem tira o pod do tráfego é a readiness.

Por que **sem limit de CPU**: limit de CPU gera throttling e latência mesmo com o nó ocioso. O request
garante o agendamento e é a base do HPA; memória tem limit.

Demonstração do HPA:

```bash
scripts/load-test.sh 8 180                  # carga de dentro do cluster
kubectl -n realworld get hpa api --watch
```

## 3. Pipeline CI/CD (GitHub Actions)

**[CI](.github/workflows/ci.yml)**: todo pull request (e reaproveitado pelo CD). 4 jobs em paralelo:

| Job | O que valida |
|---|---|
| App | build, testes unitários com **Postgres real** como service container, migrations, lint do código novo (bloqueia) e do herdado (informativo) |
| Lint de infraestrutura | hadolint (Dockerfile), shellcheck (scripts), actionlint (workflows), `docker compose config`, kustomize + kubeconform (manifests) |
| Imagem + Compose e2e | build, Trivy (bloqueia CRITICAL com correção), sobe o Compose com observabilidade, smoke test, confere não-root, confere que logs chegaram no Loki e métricas no Prometheus |
| Kubernetes e2e | cluster kind no runner, deploy com o mesmo `kind-up.sh`, smoke test, HPA lendo métricas, Prometheus no kind, **`deploy.sh` em quatro cenários: aprovado, reprovado por taxa de erro, imagem que não sobe, e rollback para a versão comprovada em vez da "anterior"** |

**[CD](.github/workflows/cd.yml)**: push na `main` roda o CI inteiro e só então publica no GHCR:

- tags `sha-<commit>` (imutável, usada em deploy/rollback), `main`/`latest` e semver em tags `v*`;
- SBOM e atestado de proveniência gerados no build;
- assinatura **cosign keyless** (OIDC do GitHub, sem chave para guardar);
- autenticação no GHCR pelo `GITHUB_TOKEN` com `packages: write` (sem PAT).

Boas práticas nos workflows: actions de terceiros fixadas por **SHA de commit**, `permissions` mínimas por
job, `concurrency` para cancelar execuções antigas de PR, cache de camadas do BuildKit no GHA e Dependabot
mantendo actions, imagem base e npm atualizados.

Sobre o lint da aplicação: o código original tem 33 erros de ESLint (`any`, `@ts-ignore`...). O código que eu
adicionei precisa passar e bloqueia o PR; o legado aparece no resumo do job sem bloquear. CI sempre vermelho
por dívida antiga perde o valor de sinal.

## 4. Observabilidade

```bash
docker compose --profile observability up -d --build
```

| Serviço | URL | Papel |
|---|---|---|
| Grafana | http://localhost:3001 | dashboard **RealWorld API** já provisionado (usuário/senha do `.env`) |
| Prometheus | http://localhost:9090 | scrape do `/metrics` da API (descoberta por DNS: pega todas as réplicas) |
| Loki | http://localhost:3100 | armazenamento de logs |
| Alloy | http://localhost:12345 | coleta os logs dos containers pelo socket do Docker (sucessor do Promtail) |

A API loga **uma linha JSON por requisição** (`level`, `method`, `route`, `status`, `duration_ms`) e expõe
métricas Prometheus: `http_requests_total`, `http_request_duration_seconds` (histograma) e as métricas padrão
do Node (CPU, memória, event loop). O label de rota usa o template (`/api/articles/:slug`), nunca a URL crua,
para não explodir a cardinalidade.

No Alloy, só `level` vira label do Loki (poucos valores possíveis); status, rota e latência ficam no corpo e são
extraídos na consulta com `| json`.

O dashboard traz requisições/s, taxa de 5xx, latência p50/p95/p99, memória, CPU, event loop lag, volume de
logs por nível, erros e o stream de logs.

**Réplicas do kind no mesmo Grafana.** O Prometheus do Compose só vê a API do Compose. Para o dashboard mostrar
quantas réplicas estão prontas no cluster, um Prometheus pequeno roda dentro do kind ([`k8s/monitoring`](k8s/monitoring)),
descobre os pods pela anotação `prometheus.io/scrape` e guarda o estado da readiness no label `ready`. O Grafana
chega nele pelo datasource "Prometheus (kind)" via `kubectl port-forward`:

```bash
scripts/monitoring-up.sh          # aplica k8s/monitoring e abre o port-forward em localhost:9091
scripts/monitoring-up.sh --stop
```

Os dois painéis do topo ("Réplicas da API prontas no kind" e "prontas × existentes") acompanham o HPA
escalando e a readiness tirando pods do Service quando o banco cai.

Para ver os erros acontecendo:

```bash
docker compose stop postgres     # API passa a responder 500 e /readyz 503
curl -s localhost:3000/api/tags
docker compose start postgres
```

## 5. Script de automação: deploy verificado, rollback para a versão comprovada

[`scripts/deploy.sh`](scripts/deploy.sh) publica uma imagem num Deployment, espera o rollout, **verifica a
versão nova em serviço** e, se qualquer etapa falhar, volta para a **última versão comprovadamente boa**,
não para "a anterior". O raciocínio completo está em [`docs/rollback.md`](docs/rollback.md); as decisões,
comentadas no próprio script.

```bash
scripts/monitoring-up.sh                                                    # Prometheus no kind: é quem mede a versão nova
scripts/deploy.sh ghcr.io/laertegf/unecont-devops-azure:sha-<commit>        # deploy + verificação → registrada como boa
scripts/deploy.sh ghcr.io/laertegf/unecont-devops-azure:nao-existe -t 60s   # não sobe → rollback
scripts/deploy.sh realworld-api:com-falha -w 30                             # sobe Ready mas erra → rollback
scripts/deploy.sh --rollback                                                # volta para a última comprovada, com verificação
kubectl -n realworld get deploy api -o jsonpath='{.metadata.annotations}'   # last-good-image / revision / at
```

Por que "voltar a imagem anterior" não basta, e o que o script faz no lugar:

| Buraco do rollback comum | Resposta do script |
|---|---|
| **Alvo**: a anterior pode ser tão ruim quanto a atual (dois deploys ruins seguidos, `set image` na mão) | só registra como boa (`deploy.realworld.io/last-good-*`) a versão que passou na verificação; o rollback volta para ela, por revisão ou por imagem |
| **Gatilho**: readiness só pega pod que nem sobe; versão Ready que devolve 500 fica no ar | após o rollout: smoke test + janela medindo no Prometheus a taxa de 5xx e o p95 **só dos pods da versão nova** (filtro pelo hash do ReplicaSet); limites `-e` e `-l` |
| **Banco**: rollback de imagem não desfaz migração, e o Prisma não tem "down" | compara `_prisma_migrations` antes e depois; no rollback lista o que entrou e avisa que a versão antiga passa a rodar sobre o schema novo (seguro só com expand/contract) |
| Rollback é tratado como "desfazer", não como deploy | `--rollback` passa pela mesma verificação: voltar para uma versão que já não funciona é um deploy ruim como outro |

Ainda valem: timeout explícito do rollout, diagnóstico coletado **antes** do rollback, API e initContainer
de migração atualizados juntos, códigos de saída para o pipeline (`0` aprovado, `1` pré-condição, `2` reprovado
e voltou, `3` reprovado e não voltou). Sem Prometheus ou sem amostra suficiente, a versão fica no ar mas não
é registrada como boa: não se aprova o que não se mediu.

A versão que "sobe mas erra" existe de propósito para testar o pipeline: a variável `CHAOS_ERROR_RATE`
([`src/app/observability/fault.ts`](src/app/observability/fault.ts)) faz a API responder 500 numa fração das
chamadas em `/api`, sem tocar nas probes. O CI builda uma imagem derivada com ela e confere que o script
reprova e volta para a comprovada, inclusive no cenário em que "a anterior" é uma versão ruim publicada por fora.

## Mudanças na aplicação

Só o necessário para operar a API em container e Kubernetes (`src/main.ts` e `src/app/observability/`):

- `/healthz` (liveness) e `/readyz` (readiness, checa o banco);
- `/metrics` com `prom-client`;
- log estruturado em JSON por requisição, e erros 5xx logados com stack;
- desligamento gracioso no SIGTERM (readiness passa a 503, fecha o servidor e o pool do Prisma).

## Em produção, o que eu faria diferente (Azure)

| Aqui | Em produção |
|---|---|
| kind | **AKS** com node pools separados (sistema/aplicação), autoscaler de nós, zonas de disponibilidade |
| Postgres no cluster | **Azure Database for PostgreSQL Flexible Server** com HA, backup e acesso por Private Endpoint |
| Secret gerado localmente | **Azure Key Vault** + Secrets Store CSI Driver, autenticação por **Workload Identity** |
| GHCR | **ACR** com integração ao AKS, geo-replicação e quarentena/scan (Defender for Containers) |
| `kubectl` no pipeline | **GitOps** (Argo CD ou Flux) com promoção dev → hml → prod por PR; GitHub Actions autenticando no Azure por **OIDC** (sem client secret) |
| verificação pós-rollout no `deploy.sh` | **Argo Rollouts** ou Flagger: canário com divisão de tráfego e AnalysisTemplate no Prometheus (o script é a versão manual disso, sem canário) |
| NodePort | Application Gateway for Containers ou ingress gerenciado, TLS com cert-manager, WAF |
| Stack no Compose | **Azure Monitor managed Prometheus + Azure Managed Grafana**, ou a mesma stack LGTM no cluster com Loki em Blob Storage; alertas por SLO (taxa de erro, p95) |
| Segurança | políticas de admissão (Azure Policy/Kyverno) exigindo imagem assinada e do registry interno, imagem distroless, NetworkPolicy default-deny |
| App | remover o fallback de `JWT_SECRET` do código (hoje cai em um valor fixo se a variável faltar) e tracing com OpenTelemetry |

## Estrutura

```
.
├── Dockerfile, .dockerignore
├── docker-compose.yml, .env.example
├── k8s/
│   ├── kind-cluster.yaml
│   ├── base/                 # namespace, postgres, deployment, service, hpa, pdb, networkpolicy
│   ├── overlays/kind/        # NodePort + secretGenerator
│   └── monitoring/           # Prometheus dentro do kind (réplicas no Grafana)
├── observability/            # prometheus, loki, alloy, grafana (datasources + dashboard)
├── scripts/                  # deploy.sh, kind-up.sh, kind-down.sh, monitoring-up.sh, load-test.sh, smoke-test.sh
├── .github/workflows/        # ci.yml, cd.yml
├── docs/                     # demo.md (roteiro da apresentação), rollback.md (por que não basta voltar a imagem anterior)
└── src/                      # aplicação (upstream RealWorld + observabilidade)
```
