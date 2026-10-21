#!/usr/bin/env bash
# Aplica os manifestos k8s/ (a numeracao dos arquivos garante a ordem de criacao).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$ROOT_DIR"

NAMESPACE="fcg"

# Regera k8s/03-kong-config.yaml de kong/kong.yml, para nunca aplicar uma
# config de gateway defasada em relacao a fonte que o Compose usa.
echo "==> Sincronizando o ConfigMap do Kong"
"$SCRIPT_DIR/../kong/sync-configmap.sh"

# O script que cria a tabela do DynamoDB Local do NotificationsAPI (SOMENTE LOCAL)
# chega ao pod por um ConfigMap GERADO de notifications-local/init-dynamodb.sh --
# mesma ideia do ConfigMap do Kong: uma fonte so, sem copia colada no manifesto.
# O namespace precisa existir antes do ConfigMap.
echo "==> Gerando o ConfigMap do init do DynamoDB Local (notifications)"
kubectl apply -f k8s/00-namespace.yaml >/dev/null
kubectl create configmap notifications-dynamodb-init -n "$NAMESPACE" \
  --from-file=init-dynamodb.sh=notifications-local/init-dynamodb.sh \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

echo "==> Aplicando manifestos de k8s/"
kubectl apply -f k8s/

# Os manifestos versionados trazem a license key do New Relic e as credenciais
# da AWS como PLACEHOLDER. Este script sobrepoe com os valores reais do .env --
# tem de rodar DEPOIS do apply, senao o placeholder volta por cima.
echo "==> Aplicando segredos reais do .env"
"$SCRIPT_DIR/secrets.sh"

# O init da tabela so roda na subida do pod: trocar o ConfigMap nao o re-executa.
# Mesmo truque do Kong -- o hash do script no pod template faz o Deployment rolar
# quando (e somente quando) o script mudou.
INIT_HASH="$(cat notifications-local/init-dynamodb.sh | sha256sum | cut -c1-12)"
kubectl patch deployment notifications-dynamodb -n "$NAMESPACE" --type=merge -p \
  "{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"fcg.dev/dynamodb-init-hash\":\"${INIT_HASH}\"}}}}}" >/dev/null

# O Kong le a config declarativa UMA VEZ, no startup: trocar o ConfigMap nao
# faz efeito nos pods que ja estao rodando. Copiamos o hash da config para uma
# annotation do pod template -- o `kubectl patch` e idempotente, entao o
# Deployment SO rola quando kong/kong.yml (ou o render-and-start.sh) mudou.
KONG_CONFIG_HASH="$(kubectl get configmap kong-declarative -n "$NAMESPACE" \
  -o jsonpath='{.metadata.annotations.fcg\.dev/kong-config-hash}' 2>/dev/null || true)"

if [ -n "$KONG_CONFIG_HASH" ]; then
  echo "==> Propagando o hash da config do Kong para o Deployment (${KONG_CONFIG_HASH})"
  kubectl patch deployment kong -n "$NAMESPACE" --type=merge -p \
    "{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"fcg.dev/kong-config-hash\":\"${KONG_CONFIG_HASH}\"}}}}}"
else
  echo "!! Nao foi possivel ler a annotation de hash do ConfigMap kong-declarative." >&2
  echo "   Se editou kong/kong.yml, rode: kubectl rollout restart deployment/kong -n $NAMESPACE" >&2
fi

echo "==> Manifestos aplicados."