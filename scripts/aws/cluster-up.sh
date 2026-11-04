#!/usr/bin/env bash
# Sobe o cluster EKS efemero da FCG:
#   1. rede permanente (stack fcg-network; idempotente, normalmente "No changes")
#   2. cluster, NAT e nodes (stack fcg-eks; 15-20 min)
#   3. kubectl apontando para o cluster + manifestos que so valem na AWS (k8s/aws/)
#
# Tudo da stack fcg-eks e cobrado por hora. Derrube com `make cluster-down` quando
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
CLUSTER_NAME="${CLUSTER_NAME:-fcg}"

# Mostra a conta antes de criar qualquer coisa: sem AWS_PROFILE, o CLI usa o profile
# default, que pode ser uma conta pessoal (ja aconteceu com o ECR).
account="$(aws sts get-caller-identity --query Account --output text)"
echo "==> Conta AWS: $account (profile: ${AWS_PROFILE:-default}) | regiao: $REGION"

echo "==> [1/3] Rede permanente ($NETWORK_STACK)"
aws cloudformation deploy \
  --template-file infra/cloudformation/vpc.yaml \
  --stack-name "$NETWORK_STACK" \
  --region "$REGION" \
  --no-fail-on-empty-changeset

echo "==> [2/3] Cluster EKS ($EKS_STACK) - leva de 15 a 20 minutos"
aws cloudformation deploy \
  --template-file infra/cloudformation/eks.yaml \
  --stack-name "$EKS_STACK" \
  --region "$REGION" \
  --capabilities CAPABILITY_IAM CAPABILITY_AUTO_EXPAND \
  --parameter-overrides "ClusterName=$CLUSTER_NAME" \
  --no-fail-on-empty-changeset

echo "==> [3/3] kubectl e manifestos da AWS"
# --alias fcg-eks: o contexto ganha um nome legivel. Atencao: ele vira o contexto
# atual, entao o proximo `make k8s-deploy` vai para o EKS, nao para o Minikube
# (`minikube start` ou `kubectl config use-context minikube` volta).
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION" --alias fcg-eks
kubectl apply -f k8s/aws/

kubectl get nodes -o custom-columns='NODE:.metadata.name,STATUS:.status.conditions[-1].type,PODS:.status.allocatable.pods,ZONE:.metadata.labels.topology\.kubernetes\.io/zone'
echo "==> Cluster no ar. Lembre de derrubar com 'make cluster-down'."
