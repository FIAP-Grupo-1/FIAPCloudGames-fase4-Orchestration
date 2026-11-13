#!/usr/bin/env bash
# Sobe os workloads da FCG no EKS (o equivalente do `make k8s-deploy` do Minikube):
#   1. External Secrets Operator (Helm) - le o Secrets Manager via Pod Identity
#   2. ClusterSecretStore + ExternalSecrets (k8s/aws/workloads/) -> fcg-secrets e new-relic
#   3. manifestos de k8s/ com as imagens trocadas pelas do ECR
#   4. espera os rollouts e mostra o endereco publico (NLB do Kong)
#
# Pre-requisitos, nesta ordem:
#   make secrets-deploy        (uma vez; segredos e roles, stack permanente)
#   make cluster-up            (cluster efemero, kubectl no contexto fcg-eks)
#   make pod-identity-deploy   (liga as roles as ServiceAccounts)
# Ferramentas: aws, kubectl, helm (Windows: winget install Helm.Helm).
#
# Ficam de fora: os Secrets (no Minikube vem do .env via scripts/k8s/secrets.sh; no EKS vem do
# ESO), 13/23 (DynamoDB e Lambda emulados; na AWS sao os reais) e 30-ingress.yaml
# (nginx do Minikube; no EKS a entrada e o NLB de k8s/aws/workloads/02-kong-public.yaml).
#
# Tag das imagens: a maior release v* de cada repositorio ECR (git tag v1.0.0 no repo da
# API dispara a pipeline); sem release, a sha-* mais recente. Para fixar uma, exporte
# USERS_API_TAG, CATALOG_API_TAG ou PAYMENTS_API_TAG (ex.: v1.0.0 ou sha-1a2b3c4).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../k8s/common.sh"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$ROOT_DIR"

REGION="${AWS_REGION:-us-east-1}"
NAMESPACE="${NAMESPACE:-fcg}"
EXPECTED_CONTEXT="${EXPECTED_CONTEXT:-fcg-eks}"
# Versao do chart fixada (CRDs servem external-secrets.io/v1, usada em k8s/aws/workloads/).
ESO_VERSION="${ESO_VERSION:-2.14.0}"

# Trava de seguranca: as imagens do ECR nao existem no Minikube e vice-versa.
context="$(kubectl config current-context)"
if [[ "$context" != "$EXPECTED_CONTEXT" ]]; then
  echo "!! kubectl esta no contexto '$context', esperado '$EXPECTED_CONTEXT'." >&2
  echo "   Rode 'make cluster-up' ou 'kubectl config use-context $EXPECTED_CONTEXT'." >&2
  exit 1
fi

account="$(aws sts get-caller-identity --query Account --output text)"
registry="$account.dkr.ecr.$REGION.amazonaws.com"
echo "==> Conta AWS: $account | regiao: $REGION | contexto: $context"

echo "==> [1/4] External Secrets Operator (Helm)"
helm repo add external-secrets https://charts.external-secrets.io >/dev/null 2>&1 || true
helm repo update external-secrets >/dev/null
# Namespace e ServiceAccount padrao do chart: os mesmos da associacao do Pod Identity.
helm upgrade --install external-secrets external-secrets/external-secrets \
  --namespace external-secrets --create-namespace \
  ${ESO_VERSION:+--version "$ESO_VERSION"} \
  --wait --timeout 5m
helm list -n external-secrets --filter '^external-secrets$' -o table

echo "==> [2/4] Segredos do Secrets Manager -> Secrets do Kubernetes"
kubectl apply -f k8s/00-namespace.yaml
kubectl apply -f k8s/aws/workloads/
# Sem os Secrets os pods ficariam em CreateContainerConfigError; melhor falhar aqui.
kubectl wait --for=condition=Ready externalsecret/fcg-secrets externalsecret/new-relic \
  -n "$NAMESPACE" --timeout=120s

echo "==> [3/4] Manifestos com imagens do ECR"
# 1o a maior tag de release v* (nunca expira na lifecycle do ECR). Sem nenhuma, a
# imagem com tag mais recente (sha-*, expira em 15 dias). O filtro imageDetails[?imageTags]
# e necessario: cada push gera um index com tag e dois manifests filhos sem tag.
latest_tag() {
  local tag
  tag="$(aws ecr describe-images --repository-name "fcg/$1" --region "$REGION" \
    --query "imageDetails[].imageTags[] | [?starts_with(@, 'v')]" --output text |
    tr '\t' '\n' | sort -V | tail -n 1)"
  if [[ -z "$tag" || "$tag" == "None" ]]; then
    tag="$(aws ecr describe-images --repository-name "fcg/$1" --region "$REGION" \
      --query 'sort_by(imageDetails[?imageTags], &imagePushedAt)[-1].imageTags[0]' --output text)"
    [[ -n "$tag" && "$tag" != "None" ]] &&
      echo "   aviso: fcg/$1 sem tag v*; usando $tag, que expira em 15 dias (crie uma tag git v*)." >&2
  fi
  printf '%s' "$tag"
}
users_tag="${USERS_API_TAG:-$(latest_tag users-api)}"
catalog_tag="${CATALOG_API_TAG:-$(latest_tag catalog-api)}"
payments_tag="${PAYMENTS_API_TAG:-$(latest_tag payments-api)}"
for pair in "users-api:$users_tag" "catalog-api:$catalog_tag" "payments-api:$payments_tag"; do
  if [[ -z "${pair#*:}" || "${pair#*:}" == "None" ]]; then
    echo "!! Nenhuma imagem com tag em fcg/${pair%%:*} no ECR. Rode a pipeline do repo antes." >&2
    exit 1
  fi
  echo "    fcg/$pair"
done

# O kubectl apply recebe os manifestos ja com a imagem do ECR; os arquivos do repo
# continuam com fcg/*:1.0 para o Minikube.
for f in 01-configmap 03-kong-config 05-service-accounts 10-rabbitmq 11-postgres 12-redis \
         20-users-api 21-catalog-api 22-payments-api 24-kong; do
  sed -e "s#image: fcg/users-api:1.0#image: $registry/fcg/users-api:$users_tag#" \
      -e "s#image: fcg/catalog-api:1.0#image: $registry/fcg/catalog-api:$catalog_tag#" \
      -e "s#image: fcg/payments-api:1.0#image: $registry/fcg/payments-api:$payments_tag#" \
      "k8s/$f.yaml"
  # Quebra de linha antes do separador: um arquivo sem "\n" no fim (ex.: 24-kong.yaml)
  # grudava o "---" na ultima linha e o apply recusava ("targetPort: 8100---").
  printf '\n---\n'
done | kubectl apply -f -

echo "==> [4/4] Aguardando os rollouts"
for d in postgres redis rabbitmq users-api catalog-api payments-api kong; do
  kubectl rollout status "deployment/$d" -n "$NAMESPACE" --timeout=5m
done

# O NLB leva alguns minutos para ganhar DNS e passar no health check.
host=""
for _ in $(seq 1 30); do
  host="$(kubectl get service kong-public -n "$NAMESPACE" \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
  [[ -n "$host" ]] && break
  sleep 10
done
echo "==> Workloads no ar."
if [[ -n "$host" ]]; then
  echo "    Gateway: http://$host  (ex.: http://$host/payments/health)"
else
  echo "    NLB ainda sem DNS: kubectl get service kong-public -n $NAMESPACE -w"
fi
