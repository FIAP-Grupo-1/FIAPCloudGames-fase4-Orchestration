#!/usr/bin/env bash
# Derruba o cluster EKS efemero (stack fcg-eks). A rede (fcg-network) fica: nao cobra
# por hora e deixa o proximo cluster-up mais rapido.
#
# ----------------------------------------------------------------------
# POR QUE NAO E SO `delete-stack`
# ----------------------------------------------------------------------
# O NLB do Kong (Service type LoadBalancer) e os volumes EBS dos PVCs sao criados
# pelo Kubernetes, nao pelo CloudFormation. Apagar so a stack deixaria os dois
# orfaos, cobrando sozinhos. Por isso apagamos antes o namespace fcg: o finalizer
# do Service espera o LB sumir, e o PVC leva o volume junto (reclaimPolicy Delete).
# Os dados do Postgres somem com ele.
#
# A stack fcg-pod-identity (associacoes) importa o cluster e precisa sair
# antes da fcg-eks; senao fica orfa e o proximo pod-identity-deploy falha.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../k8s/common.sh"

REGION="${AWS_REGION:-us-east-1}"
EKS_STACK="${EKS_STACK:-fcg-eks}"
POD_IDENTITY_STACK="${POD_IDENTITY_STACK:-fcg-pod-identity}"
CLUSTER_NAME="${CLUSTER_NAME:-fcg}"
NAMESPACE="fcg"

account="$(aws sts get-caller-identity --query Account --output text)"
echo "==> Conta AWS: $account (profile: ${AWS_PROFILE:-default}) | regiao: $REGION"

if ! aws cloudformation describe-stacks --stack-name "$EKS_STACK" --region "$REGION" >/dev/null 2>&1; then
  echo "==> Stack $EKS_STACK nao existe; nada a derrubar."
  exit 0
fi

if aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" >/dev/null 2>&1; then
  echo "==> [1/4] Removendo os recursos criados pelo Kubernetes (LB e volumes)"
  aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION" --alias fcg-eks >/dev/null
  kubectl --context fcg-eks delete namespace "$NAMESPACE" --ignore-not-found --wait=true --timeout=10m
  # O PV (e o volume EBS por tras) e apagado de forma assincrona depois do PVC.
  kubectl --context fcg-eks wait --for=delete pv --all --timeout=5m 2>/dev/null || true
else
  echo "==> [1/4] Cluster nao responde; pulando a limpeza pelo kubectl"
fi

if aws cloudformation describe-stacks --stack-name "$POD_IDENTITY_STACK" --region "$REGION" >/dev/null 2>&1; then
  echo "==> [2/4] Apagando a stack $POD_IDENTITY_STACK"
  aws cloudformation delete-stack --stack-name "$POD_IDENTITY_STACK" --region "$REGION"
  aws cloudformation wait stack-delete-complete --stack-name "$POD_IDENTITY_STACK" --region "$REGION"
else
  echo "==> [2/4] $POD_IDENTITY_STACK nao existe; nada a apagar"
fi

echo "==> [3/4] Apagando a stack $EKS_STACK - leva de 10 a 15 minutos"
aws cloudformation delete-stack --stack-name "$EKS_STACK" --region "$REGION"
aws cloudformation wait stack-delete-complete --stack-name "$EKS_STACK" --region "$REGION"

echo "==> [4/4] Procurando sobras que continuariam cobrando"
leftovers="$(aws resourcegroupstaggingapi get-resources --region "$REGION" \
  --tag-filters "Key=kubernetes.io/cluster/$CLUSTER_NAME,Values=owned" \
  --query 'ResourceTagMappingList[].ResourceARN' --output text)"
volumes="$(aws ec2 describe-volumes --region "$REGION" \
  --filters Name=tag-key,Values=kubernetes.io/created-for/pvc/name Name=status,Values=available \
  --query 'Volumes[].VolumeId' --output text)"

if [ -n "$leftovers" ] || [ -n "$volumes" ]; then
  echo "!! Sobraram recursos criados pelo cluster (apague no console ou com o CLI):" >&2
  # A saida --output text do CLI separa os itens por tab: um por linha.
  [ -n "$leftovers" ] && tr '\t' '\n' <<< "$leftovers" | sed 's/^/   /' >&2
  [ -n "$volumes" ] && tr '\t' '\n' <<< "$volumes" | sed 's/^/   volume EBS /' >&2
  exit 1
fi

kubectl config delete-context fcg-eks >/dev/null 2>&1 || true
echo "==> Cluster derrubado. Nada sobrando com a tag do cluster."
