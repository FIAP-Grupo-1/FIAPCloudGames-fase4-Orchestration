#!/usr/bin/env bash
# Monta, no Minikube, os Secrets fcg-secrets e new-relic a partir do .env (que
# nunca vai para o git). Nenhuma senha fica versionada: o antigo k8s/02-secret.yaml
# (com valores de exemplo) saiu do repositorio.
#
# No EKS os MESMOS Secrets (mesmos nomes e chaves) vem do AWS Secrets Manager via
# External Secrets (k8s/aws/workloads/01-external-secrets.yaml); os Deployments
# nao mudam entre um ambiente e outro.
#
# Mesma ideia do sync-configmap.sh: uma fonte de verdade so (.env, o mesmo que o
# Compose usa) em vez de duas copias que desencontram.
#
# E idempotente e roda ANTES do `kubectl apply -f k8s/`, para os pods ja nascerem
# com o Secret pronto (ver deploy.sh).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$ROOT_DIR"

NAMESPACE="fcg"

if [ -f "$ROOT_DIR/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  source "$ROOT_DIR/.env"
  set +a
else
  echo "!! .env nao encontrado em $ROOT_DIR -- copie de .env.example e preencha." >&2
  exit 1
fi

# Obrigatorias: sem elas os bancos e o login nao funcionam.
missing=()
for v in POSTGRES_PASSWORD REDIS_PASS RABBITMQ_PASS JWT_SECRET_KEY; do
  [ -n "${!v:-}" ] || missing+=("$v")
done
if [ "${#missing[@]}" -gt 0 ]; then
  echo "!! Variaveis obrigatorias vazias no .env: ${missing[*]}" >&2
  exit 1
fi

PG_USER="${POSTGRES_USER:-fcg}"
REDIS_USER="${REDIS_USER:-fcg}"
kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 || kubectl apply -f k8s/00-namespace.yaml >/dev/null

# ---------- fcg-secrets ----------
# Mesmas chaves que o ExternalSecret do EKS monta.
args=(
  --from-literal=RabbitMq__Password="$RABBITMQ_PASS"
  --from-literal=JwtSettings__SecretKey="$JWT_SECRET_KEY"
  --from-literal=Users__ConnectionString="Host=postgres;Port=5432;Database=fcgdb;Username=$PG_USER;Password=$POSTGRES_PASSWORD"
  --from-literal=Catalog__ConnectionString="Host=postgres;Database=catalogdb;Username=$PG_USER;Password=$POSTGRES_PASSWORD"
  --from-literal=Payments__ConnectionString="Host=postgres;Database=paymentsdb;Username=$PG_USER;Password=$POSTGRES_PASSWORD"
  # `abortConnect=false` deixa o app subir mesmo com o Redis ainda fora do ar.
  --from-literal=Catalog__RedisConnection="redis:6379,user=$REDIS_USER,password=$REDIS_PASS,abortConnect=false"
  --from-literal=Users__RedisConnection="redis:6379,user=$REDIS_USER,password=$REDIS_PASS,abortConnect=false"
  --from-literal=Postgres__Password="$POSTGRES_PASSWORD"
  --from-literal=Redis__Password="$REDIS_PASS"
)
if [ -n "${ADMIN_PASSWORD:-}" ]; then
  args+=(--from-literal=Seed__AdminPassword="$ADMIN_PASSWORD")
else
  echo "!! ADMIN_PASSWORD vazia no .env -- o users-api sobe sem criar o admin raiz." >&2
fi
# Credenciais AWS: so no Minikube (no EKS o SNS usa Pod Identity, sem chave).
if [ -n "${AWS_ACCESS_KEY_ID:-}" ] && [ -n "${AWS_SECRET_ACCESS_KEY:-}" ]; then
  args+=(--from-literal=AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID"
         --from-literal=AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY")
else
  echo "!! AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY vazias no .env." >&2
  echo "   users-api e payments-api vao subir, mas o publish no SNS falha e o" >&2
  echo "   evento e perdido -- a Lambda na AWS nao sera acionada." >&2
fi
kubectl create secret generic fcg-secrets -n "$NAMESPACE" "${args[@]}" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
echo "==> Secret fcg-secrets montado a partir do .env"

# ---------- New Relic ----------
if [ -n "${NEW_RELIC_LICENSE_KEY:-}" ]; then
  kubectl create secret generic new-relic -n "$NAMESPACE" \
    --from-literal=license-key="$NEW_RELIC_LICENSE_KEY" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  echo "==> Secret new-relic atualizado a partir do .env"
else
  echo "!! NEW_RELIC_LICENSE_KEY vazia no .env -- os agentes vao subir sem reportar." >&2
fi

# Os pods leem Secret por variavel de ambiente, e isso e resolvido UMA VEZ, na
# criacao do container: trocar o Secret NAO afeta quem ja esta rodando.
#
# Mesmo truque do ConfigMap do Kong (ver sync-configmap.sh): gravamos o hash dos
# valores numa annotation do pod template. O `kubectl patch` e idempotente, entao o
# Deployment so rola quando o segredo realmente mudou. So o hash vai para a
# annotation, nunca o valor.
SECRETS_HASH="$(kubectl get secret fcg-secrets new-relic -n "$NAMESPACE" -o jsonpath='{.items[*].data}' 2>/dev/null \
  | sha256sum | cut -c1-12)"

for d in users-api catalog-api payments-api; do
  if kubectl get deployment "$d" -n "$NAMESPACE" >/dev/null 2>&1; then
    kubectl patch deployment "$d" -n "$NAMESPACE" --type=merge -p \
      "{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"fcg.dev/secrets-hash\":\"${SECRETS_HASH}\"}}}}}" >/dev/null
  fi
done
echo "==> Hash dos segredos propagado para os Deployments (${SECRETS_HASH})"
