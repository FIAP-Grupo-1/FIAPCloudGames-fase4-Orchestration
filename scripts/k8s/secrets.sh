#!/usr/bin/env bash
# Sobrescreve, no cluster, os segredos que os manifestos versionados so trazem
# como PLACEHOLDER -- lendo os valores reais do .env (que nunca vai para o git).
#
# Por que este script existe
# --------------------------
# k8s/02-secret.yaml e k8s/04-new-relic-secret.yaml sao versionados, entao nao
# podem conter a license key do New Relic nem as credenciais da AWS. Eles trazem
# "COLOQUE_SUA_CHAVE_AQUI"/"SUBSTITUA_AQUI", e um `kubectl apply -f k8s/` sobe o
# cluster com esses valores de mentira. O sintoma nao e um erro claro:
#   - license key invalida  -> o agente New Relic sobe e NAO reporta nada;
#   - credencial AWS falsa  -> o publish no SNS falha e o evento e PERDIDO,
#                              depois de ~16s travado na cadeia de credenciais.
#
# Mesma ideia do sync-configmap.sh: uma fonte de verdade so (.env, o mesmo que o
# Compose usa) em vez de duas copias que desencontram.
#
# E idempotente e roda DEPOIS do `kubectl apply -f k8s/`, para sobrepor o
# placeholder. Se uma variavel nao estiver no .env, avisa e segue -- o cluster
# sobe igual, so sem aquela integracao.
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

# ---------- New Relic ----------
# O Secret inteiro tem uma chave so, entao da para recria-lo por completo.
if [ -n "${NEW_RELIC_LICENSE_KEY:-}" ]; then
  kubectl create secret generic new-relic -n "$NAMESPACE" \
    --from-literal=license-key="$NEW_RELIC_LICENSE_KEY" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  echo "==> Secret new-relic atualizado a partir do .env"
else
  echo "!! NEW_RELIC_LICENSE_KEY vazia no .env -- os agentes vao subir sem reportar." >&2
fi

# ---------- AWS ----------
# Aqui NAO da para recriar o Secret: fcg-secrets guarda tambem as connection
# strings e o segredo do JWT, que continuam vindo do manifesto. Entao so
# aplicamos um patch nas duas chaves da AWS (`|| true` nao serve: queremos saber
# se o patch falhou).
if [ -n "${AWS_ACCESS_KEY_ID:-}" ] && [ -n "${AWS_SECRET_ACCESS_KEY:-}" ]; then
  AK_B64="$(printf '%s' "$AWS_ACCESS_KEY_ID"     | base64 | tr -d '\n')"
  SK_B64="$(printf '%s' "$AWS_SECRET_ACCESS_KEY" | base64 | tr -d '\n')"
  kubectl patch secret fcg-secrets -n "$NAMESPACE" --type=merge -p \
    "{\"data\":{\"AWS_ACCESS_KEY_ID\":\"${AK_B64}\",\"AWS_SECRET_ACCESS_KEY\":\"${SK_B64}\"}}" >/dev/null
  echo "==> Credenciais AWS aplicadas em fcg-secrets a partir do .env"
else
  echo "!! AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY vazias no .env." >&2
  echo "   users-api e payments-api vao subir, mas o publish no SNS falha e o" >&2
  echo "   evento e perdido -- a Lambda na AWS nao sera acionada." >&2
fi

# Os pods leem Secret por variavel de ambiente, e isso e resolvido UMA VEZ, na
# criacao do container: trocar o Secret NAO afeta quem ja esta rodando.
#
# Mesmo truque do ConfigMap do Kong (ver sync-configmap.sh): em vez de um
# `rollout restart` cego a cada deploy, gravamos o hash dos valores numa
# annotation do pod template. O `kubectl patch` e idempotente, entao o Deployment
# so rola quando o segredo realmente mudou -- e um `make k8s-deploy` repetido nao
# derruba os pods a toa.
#
# So o hash vai para a annotation, nunca o valor.
SECRETS_HASH="$(printf '%s|%s|%s' \
  "${NEW_RELIC_LICENSE_KEY:-}" "${AWS_ACCESS_KEY_ID:-}" "${AWS_SECRET_ACCESS_KEY:-}" \
  | sha256sum | cut -c1-12)"

for d in users-api catalog-api payments-api; do
  if kubectl get deployment "$d" -n "$NAMESPACE" >/dev/null 2>&1; then
    kubectl patch deployment "$d" -n "$NAMESPACE" --type=merge -p \
      "{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"fcg.dev/secrets-hash\":\"${SECRETS_HASH}\"}}}}}" >/dev/null
  fi
done
echo "==> Hash dos segredos propagado para os Deployments (${SECRETS_HASH})"
