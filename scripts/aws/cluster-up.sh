#!/usr/bin/env bash
# Sobe o cluster EKS efemero da FCG:
#   1. rede permanente (stack fcg-network; idempotente, normalmente "No changes")
#   2. cluster, NAT e nodes (stack fcg-eks; 15-20 min) e, em paralelo, o Amazon
#      OpenSearch da busca do catalog-api (stack fcg-search; mesmos 15-20 min)
#   3. Pod Identity (stack fcg-pod-identity), se os segredos/roles (fcg-workload-access)
#      ja existirem
#   4. kubectl apontando para o cluster + manifestos que so valem na AWS (k8s/aws/)
#
# Os workloads sobem depois, com `make workloads-deploy`.
#
# Tudo das stacks fcg-eks e fcg-search e cobrado por hora. Derrube com `make cluster-down` quando
# terminar de usar.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../k8s/common.sh"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$ROOT_DIR"

REGION="${AWS_REGION:-us-east-1}"
NETWORK_STACK="${NETWORK_STACK:-fcg-network}"
EKS_STACK="${EKS_STACK:-fcg-eks}"
POD_IDENTITY_STACK="${POD_IDENTITY_STACK:-fcg-pod-identity}"
SEARCH_STACK="${SEARCH_STACK:-fcg-search}"
SECRETS_STACK="${SECRETS_STACK:-fcg-workload-access}"
TEAM_STACK="${TEAM_STACK:-fcg-team-access}"
CLUSTER_NAME="${CLUSTER_NAME:-fcg}"

# Mostra a conta antes de criar qualquer coisa: sem AWS_PROFILE, o CLI usa o profile
# default, que pode ser uma conta pessoal (ja aconteceu com o ECR).
account="$(aws sts get-caller-identity --query Account --output text)"
caller="$(aws sts get-caller-identity --query Arn --output text)"
echo "==> Conta AWS: $account (profile: ${AWS_PROFILE:-default}) | regiao: $REGION"

# REVIEW_IN_PROGRESS = stack que nunca foi criada (o change set de criacao falhou):
# para os parametros "so na criacao", conta como inexistente.
stack_exists() {
  local status
  status="$(aws cloudformation describe-stacks --stack-name "$1" --region "$REGION" \
    --query 'Stacks[0].StackStatus' --output text 2>/dev/null)" || return 1
  [ "$status" != "REVIEW_IN_PROGRESS" ]
}

# Acesso do grupo ao cluster. Com usuarios individuais (stack fcg-team-access), cada
# fcg-<membro> ganha uma access entry de admin. O admin automatico do criador so fica
# ligado se quem roda nao for um deles: o EKS recusa duas entries para o mesmo usuario.
eks_params=("ClusterName=$CLUSTER_NAME")
members="$(aws cloudformation describe-stacks --stack-name "$TEAM_STACK" --region "$REGION" \
  --query "Stacks[0].Parameters[?ParameterKey=='Members'].ParameterValue" --output text 2>/dev/null || true)"
if [ -n "$members" ] && [ "$members" != "None" ]; then
  eks_params+=("TeamAccess=true" "TeamMembers=$members")
  bootstrap=true
  for m in ${members//,/ }; do
    [[ "$caller" == *":user/fcg-$m" ]] && bootstrap=false
  done
  echo "    acesso ao cluster: usuarios fcg-{$members}"
else
  eks_params+=("TeamAccess=false")
  bootstrap=true
  echo "    acesso ao cluster: so quem cria ($caller)"
fi
# BootstrapCreatorAdmin so vale na criacao. Com o cluster ja de pe, omitir o parametro
# mantem o valor atual (o deploy reaproveita parametros nao informados), em vez de
# tentar mudar algo que o EKS nao deixa mudar.
if ! stack_exists "$EKS_STACK"; then
  eks_params+=("BootstrapCreatorAdmin=$bootstrap")
fi

echo "==> [1/4] Rede permanente ($NETWORK_STACK)"
aws cloudformation deploy \
  --template-file infra/cloudformation/vpc.yaml \
  --stack-name "$NETWORK_STACK" \
  --region "$REGION" \
  --no-fail-on-empty-changeset

# OpenSearch (busca do catalog-api): leva os mesmos 15-20 min do EKS e nao depende
# dele, entao sobe em paralelo. A politica de acesso referencia a role do catalog-api,
# que vem da fcg-workload-access.
search_pid=""
search_log="$(mktemp)"
if stack_exists "$SECRETS_STACK"; then
  echo "==> [2/4] OpenSearch ($SEARCH_STACK) em paralelo - log em $search_log"
  aws cloudformation deploy \
    --template-file infra/cloudformation/opensearch.yaml \
    --stack-name "$SEARCH_STACK" \
    --region "$REGION" \
    --no-fail-on-empty-changeset >"$search_log" 2>&1 &
  search_pid=$!
else
  echo "==> [2/4] OpenSearch: pulado ($SECRETS_STACK nao existe; rode 'make secrets-deploy')"
fi

echo "==> [2/4] Cluster EKS ($EKS_STACK) - leva de 15 a 20 minutos"
aws cloudformation deploy \
  --template-file infra/cloudformation/eks.yaml \
  --stack-name "$EKS_STACK" \
  --region "$REGION" \
  --capabilities CAPABILITY_IAM CAPABILITY_AUTO_EXPAND \
  --parameter-overrides "${eks_params[@]}" \
  --no-fail-on-empty-changeset

# Efemera como o cluster; o cluster-down a remove antes da fcg-eks.
if stack_exists "$SECRETS_STACK"; then
  echo "==> [3/4] Pod Identity ($POD_IDENTITY_STACK)"
  aws cloudformation deploy \
    --template-file infra/cloudformation/pod-identity.yaml \
    --stack-name "$POD_IDENTITY_STACK" \
    --region "$REGION" \
    --parameter-overrides "ClusterName=$CLUSTER_NAME" \
    --no-fail-on-empty-changeset
else
  echo "==> [3/4] Pod Identity: pulado ($SECRETS_STACK nao existe; rode 'make secrets-deploy' antes do workloads-deploy)"
fi

if [ -n "$search_pid" ]; then
  echo "==> [3/4] Aguardando o OpenSearch ($SEARCH_STACK)"
  if ! wait "$search_pid"; then
    cat "$search_log" >&2
    echo "!! O OpenSearch falhou; o cluster esta no ar, mas a busca vai ficar desligada." >&2
    echo "   Veja os eventos: aws cloudformation describe-stack-events --stack-name $SEARCH_STACK" >&2
    exit 1
  fi
  tail -n 1 "$search_log"
fi
rm -f "$search_log"

echo "==> [4/4] kubectl e manifestos da AWS"
# --alias fcg-eks: o contexto ganha um nome legivel. Atencao: ele vira o contexto
# atual, entao o proximo `make k8s-deploy` vai para o EKS, nao para o Minikube
# (`minikube start` ou `kubectl config use-context minikube` volta).
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION" --alias fcg-eks
kubectl apply -f k8s/aws/

kubectl get nodes -o custom-columns='NODE:.metadata.name,STATUS:.status.conditions[-1].type,PODS:.status.allocatable.pods,ZONE:.metadata.labels.topology\.kubernetes\.io/zone'
echo "==> Cluster no ar. Proximo passo: 'make workloads-deploy'. Para derrubar: 'make cluster-down'."
