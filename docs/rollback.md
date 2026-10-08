# Rollback: por que "voltar a imagem anterior" não basta

O rollback mais comum em Kubernetes é `kubectl rollout undo`: volta para a revisão anterior do
Deployment. Funciona na maioria dos dias e falha exatamente nos dias em que mais importa.
Este documento explica os três buracos desse modelo e como o [`scripts/deploy.sh`](../scripts/deploy.sh)
trata cada um. O CI executa os quatro cenários no job **Kubernetes e2e**.

## 1. Alvo: a anterior não é necessariamente boa

"A versão anterior" é só a última coisa que estava no ar. Ela pode ser:

- um deploy ruim que ninguém reverteu ainda (dois deploys ruins seguidos);
- um `kubectl set image` feito na mão, fora do pipeline, que nunca foi verificado;
- o resultado de um rollback anterior, que por sua vez voltou para algo não verificado.

**O que o script faz:** só registra uma versão como boa depois que ela passou na verificação
(seção 2). Ficam três anotações no Deployment:

```
deploy.realworld.io/last-good-image      ghcr.io/laertegf/unecont-devops-azure:sha-1a2b3c4
deploy.realworld.io/last-good-revision   7
deploy.realworld.io/last-good-at         2026-10-08T14:02:11Z
```

O rollback volta para **essa** versão: por revisão (`rollout undo --to-revision`) quando o ReplicaSet
dela ainda existe, o que restaura o template inteiro (imagem, config, probes); por imagem
(`set image`) quando o histórico já girou. O ReplicaSet é procurado pela imagem, não pelo número da
revisão: um `rollout undo` reaproveita o ReplicaSet antigo e o renumera, então o número anotado envelhece
e a imagem não. Sem nenhuma versão comprovada (primeiro deploy pelo script), resta a revisão anterior,
e o script avisa que ela não tem garantia.

O cenário do CI **"Rollback vai para a versão comprovada, não para a anterior"** publica uma versão
ruim por fora do pipeline (`set image` direto), deixa ela ficar Ready e então tenta um deploy que falha.
O rollback tem que pousar na versão comprovada, não na ruim que estava no ar.

## 2. Gatilho: readiness não é prova de que a versão funciona

`kubectl rollout status` termina quando os pods passam na readiness probe. Isso prova que o
processo subiu e enxerga o banco. Não prova que ele atende requisições de verdade: uma versão com
uma rota quebrada, uma query lenta ou uma dependência externa errada fica Ready e segue no ar até
alguém reclamar.

**O que o script faz:** depois do rollout, julga a versão nova em serviço:

| Verificação | Como | Limite |
|---|---|---|
| Funcional | [`smoke-test.sh`](../scripts/smoke-test.sh): cadastro, artigo, listagem, tags, métricas | passa ou falha |
| Taxa de 5xx | Prometheus, `increase(http_requests_total{pod=~"api-<hash>-.*", status_code=~"5.."}[60s])` sobre o total | `-e`, padrão 1% |
| Latência p95 | Prometheus, `histogram_quantile(0.95, …http_request_duration_seconds_bucket…)` | `-l`, padrão 500 ms |

Dois detalhes que importam:

- **Só os pods da versão nova entram na conta.** O filtro é o hash do ReplicaSet criado pelo rollout.
  Sem isso, a versão antiga (que ainda responde durante o rolling update) mascararia a nova.
- **Sem amostra não há aprovação.** Durante a janela o script gera tráfego leve de leitura para a versão
  ter o que mostrar; num ambiente real o tráfego orgânico cumpre esse papel. Se mesmo assim houver menos
  de 20 requisições, a versão fica no ar mas **não** é registrada como boa: não se aprova o que não se mediu.

Reprovou em qualquer linha: diagnóstico, rollback para a última versão comprovada, código de saída 2.

O cenário do CI **"deploy.sh reprova uma versão que sobe mas erra"** usa uma imagem derivada da imagem
normal com `CHAOS_ERROR_RATE=0.3` ([`src/app/observability/fault.ts`](../src/app/observability/fault.ts)):
ela passa nas probes e devolve 500 em 30% das chamadas em `/api`. A readiness aprova; a verificação reprova.

## 3. Banco: rollback de imagem não desfaz migração

A migração roda num initContainer (`prisma migrate deploy`) antes da API subir. Se o deploy que falhou
aplicou uma migração, o rollback da imagem deixa a **versão antiga rodando sobre o schema novo**. O Prisma
não tem migração reversa.

**O que o script faz:** lê a tabela `_prisma_migrations` antes e depois do deploy e, no rollback, lista o
que entrou:

```
14:02:40 [deploy] banco: migrações aplicadas neste deploy: 20261008120000_artigo_resumo
14:02:40 [deploy] AVISO: as migrações acima continuam aplicadas: a versão restaurada vai rodar sobre o schema novo.
14:02:40 [deploy] AVISO: isso só é seguro se elas forem compatíveis com a versão anterior (expand/contract); senão, o rollback do schema é manual.
```

A regra que torna o rollback possível é de desenvolvimento, não de ferramenta: **expand/contract**.
Uma migração só adiciona (coluna nova com default, tabela nova, índice); a remoção do que ficou velho vai
numa versão seguinte, quando ninguém mais lê aquilo. Com essa regra, versão N-1 sempre roda sobre o schema
de N. Sem ela, nenhum script resolve, e o honesto é dizer isso em vez de fingir que resolveu.

## 4. Rollback também é um deploy

`scripts/deploy.sh --rollback` volta para a última versão comprovada passando pela **mesma verificação**.
Parece redundante, mas voltar para uma versão que já não funciona (o schema mudou, uma API externa mudou,
um segredo foi rotacionado) é um deploy ruim como outro qualquer, e precisa ser tratado como tal.

## Códigos de saída

| Código | Significado | O que o pipeline faz |
|---|---|---|
| 0 | versão no ar e aprovada (ou nada a fazer, ou sem como verificar, com aviso) | segue |
| 1 | erro de uso ou pré-condição | corrige a chamada |
| 2 | reprovado (rollout ou verificação), rollback feito e saudável | falha o job, sem incidente |
| 3 | reprovado e o rollback também falhou | aciona gente |

## O que isto não é, e o que seria em produção

Isto é a versão manual do que um **AnalysisTemplate do Argo Rollouts** (ou do Flagger) faz: medir a
versão nova por métricas e abortar sozinho. A diferença é que a ferramenta faz isso com **canário e
divisão de tráfego**: a versão nova recebe 10% das requisições, é julgada, e só então recebe o resto.
Aqui a versão nova recebe 100% assim que fica Ready (rolling update), e o rollback leva o tempo de um
rollout. Em AKS, o caminho é Argo Rollouts com Application Gateway for Containers fazendo a divisão,
e o pipeline só promove o manifesto via GitOps (ver a tabela "Em produção" do [README](../README.md)).

Dois limites que ficam de fora de propósito:

- **Migração verificada antes do deploy.** Dá para rodar `prisma migrate diff` contra o banco num job
  prévio e bloquear migrações destrutivas. É pré-deploy, não rollback.
- **Tráfego orgânico.** O tráfego gerado pelo script é leitura, pouco e previsível. Num ambiente real, o
  julgamento usa o tráfego de verdade e janelas maiores.
