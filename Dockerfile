# syntax=docker/dockerfile:1.7
#
# Build em 3 estágios, com a mesma base (Debian slim) em todos:
#   build      -> instala tudo (inclusive devDependencies), gera o Prisma Client e compila com Nx/esbuild
#   prod-deps  -> instala só as dependências de produção a partir do package.json/lock gerados pelo Nx
#   runtime    -> imagem final: sem compilador, sem devDependencies, sem código-fonte TypeScript
#
# Por que Debian slim e não Alpine/distroless: o Prisma 4 escolhe o engine nativo pela libc e pela
# versão do OpenSSL no momento do "prisma generate". Buildar e rodar na mesma base evita o clássico
# "Prisma engine not found" em runtime. Distroless fica como próximo passo (ver README).

ARG NODE_IMAGE=node:22.23.3-slim

############################
FROM ${NODE_IMAGE} AS base
# openssl: exigido pelos engines do Prisma. Sem pin de versão: vem do repositório da própria base,
# que já está fixada pela tag acima.
# hadolint ignore=DL3008
RUN apt-get update \
 && apt-get install -y --no-install-recommends openssl ca-certificates \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /app

############################
FROM base AS build
# Copiar só os manifests primeiro: a camada do npm ci só é refeita quando o lockfile muda.
COPY package.json package-lock.json ./
RUN --mount=type=cache,target=/root/.npm npm ci --no-audit --no-fund

COPY nx.json project.json tsconfig.json tsconfig.app.json ./
COPY src ./src
RUN npx prisma generate \
 && npx nx build api --configuration=production --skip-nx-cache

############################
FROM base AS prod-deps
COPY --from=build /app/dist/api/package.json /app/dist/api/package-lock.json ./
# O CLI do Prisma entra na imagem de propósito: o mesmo artefato roda a API e o
# "prisma migrate deploy" (serviço migrate no compose, initContainer no Kubernetes).
# A versão do CLI acompanha a do @prisma/client resolvida pelo Nx.
RUN --mount=type=cache,target=/root/.npm \
    npm ci --omit=dev --no-audit --no-fund \
 && npm install --no-save --no-audit --no-fund \
      "prisma@$(node -p "require('./package.json').dependencies['@prisma/client']")"
COPY src/prisma ./prisma
RUN npx prisma generate --schema=prisma/schema.prisma

############################
FROM base AS runtime
LABEL org.opencontainers.image.title="realworld-api" \
      org.opencontainers.image.description="RealWorld API (Node/Express/Prisma)" \
      org.opencontainers.image.source="https://github.com/laertegf/unecont-devops-azure" \
      org.opencontainers.image.licenses="MIT"

# Tudo configurável por variável de ambiente; nenhum segredo tem default aqui.
ENV NODE_ENV=production \
    PORT=3000 \
    LOG_LEVEL=info \
    SERVICE_NAME=realworld-api \
    CHECKPOINT_DISABLE=1 \
    PRISMA_HIDE_UPDATE_MESSAGE=1

# A imagem base traz npm/npx/corepack, que a API não usa em runtime (o Prisma é chamado pelo
# binário direto). Fora da imagem: menos superfície de ataque e menos CVE no scan.
RUN rm -rf /usr/local/lib/node_modules /usr/local/bin/npm /usr/local/bin/npx /usr/local/bin/corepack

# Arquivos ficam com dono root e o processo roda como uid 1000 ("node"): a aplicação não
# consegue alterar o próprio código, o que combina com readOnlyRootFilesystem no Kubernetes.
COPY --from=prod-deps /app/node_modules ./node_modules
COPY --from=prod-deps /app/prisma ./prisma
COPY --from=build /app/dist/api ./

# uid numérico (e não "node"): o Kubernetes valida runAsNonRoot pelo número, sem precisar
# resolver o nome dentro da imagem.
USER 1000:1000
EXPOSE 3000

# Usado pelo Docker/Compose. No Kubernetes quem manda são as probes do Deployment.
HEALTHCHECK --interval=15s --timeout=3s --start-period=20s --retries=3 \
  CMD ["node", "-e", "fetch('http://127.0.0.1:'+(process.env.PORT||3000)+'/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"]

CMD ["node", "main.js"]
