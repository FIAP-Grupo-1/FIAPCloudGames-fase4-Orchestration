#!/usr/bin/env bash
# Teste fim a fim LIMPO no EKS: sobe tudo do zero, testa de verdade e derruba.
#
#   0. pre-checagem (nada pago ainda): ferramentas, conta, stacks permanentes, imagens no ECR
#   1. make cluster-up       rede + EKS + Pod Identity (15-20 min, comeca a cobrar)
#   2. make workloads-deploy ESO, Secrets, APIs com imagens do ECR, NLB do Kong
#   3. testes pelo endereco publico: health, cadastro, login, catalogo com JWT e a
#      notificacao do cadastro chegando no DynamoDB (SNS -> SQS -> Lambda)
#   4. zero downtime: zero-downtime-check em paralelo com um rollout restart
#   5. make cluster-down     SEMPRE, inclusive em erro ou Ctrl+C (trap)
#
# Uso:  make e2e                     (sobe, testa e derruba; ~45-60 min, ~US$ 0,25)
#       make e2e KEEP_CLUSTER=1      (nao derruba no fim: para gravar o video; lembre do cluster-down)
#       ZD_DEPLOYMENTS="catalog-api users-api" make e2e   (deployments reiniciados no passo 4)
# Log completo em logs/e2e-<data>.log (ignorado pelo git).
#
# O usuario de teste e criado na hora com e-mail e senha aleatorios: nada fica no repositorio.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../k8s/common.sh"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$ROOT_DIR"

REGION="${AWS_REGION:-us-east-1}"
NAMESPACE="${NAMESPACE:-fcg}"
EXPECTED_ACCOUNT="${EXPECTED_ACCOUNT:-450753703903}"
EKS_STACK="${EKS_STACK:-fcg-eks}"
KEEP_CLUSTER="${KEEP_CLUSTER:-0}"
NOTIFICATIONS_TABLE="${NOTIFICATIONS_TABLE:-fcg-notifications}"
ZD_DEPLOYMENTS="${ZD_DEPLOYMENTS:-catalog-api}"

mkdir -p logs
LOG="logs/e2e-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1

started_at="$(date '+%d/%m %H:%M')"
results=()
failed=0
cluster_created=0
zd_pid=""

step() { echo; echo "######## [$(date +%T)] $*"; }
pass() { results+=("OK     $*"); echo "   OK: $*"; }
fail() { results+=("FALHA  $*"); echo "   FALHA: $*"; failed=1; }

teardown() {
  local rc=$?
  trap - EXIT INT TERM
  [[ -n "$zd_pid" ]] && kill -TERM "$zd_pid" 2>/dev/null || true

  step "Resumo (inicio: $started_at)"
  ((${#results[@]})) && printf '   %s\n' "${results[@]}"
  ((rc != 0)) && echo "   O script parou com erro (codigo $rc): veja o log acima."

  if ((cluster_created)); then
    if [[ "$KEEP_CLUSTER" == "1" ]]; then
      step "KEEP_CLUSTER=1: o cluster CONTINUA NO AR (cobrando por hora desde $started_at)."
      echo "   Para derrubar: make cluster-down"
    else
      step "5. Derrubando o cluster (make cluster-down)"
      bash scripts/aws/cluster-down.sh ||
        echo "!! cluster-down falhou: rode 'make cluster-down' de novo e confira o console." >&2
    fi
  fi
  echo; echo "Log completo: $LOG"
  ((rc == 0 && failed == 0)) && exit 0
  exit 1
}
trap teardown EXIT
trap 'echo; echo "!! Interrompido."; exit 130' INT TERM

# ---------------------------------------------------------------------------
step "0. Pre-checagem (nada pago ate aqui)"
for t in aws kubectl helm curl; do
  command -v "$t" >/dev/null || { echo "!! Falta a ferramenta: $t" >&2; exit 1; }
done
account="$(aws sts get-caller-identity --query Account --output text)"
if [[ "$account" != "$EXPECTED_ACCOUNT" ]]; then
  echo "!! Conta AWS $account, esperada $EXPECTED_ACCOUNT (confira AWS_PROFILE)." >&2
  exit 1
fi
for s in fcg-workload-access fcg-ecr fcg-notifications-serverless; do
  aws cloudformation describe-stacks --stack-name "$s" --region "$REGION" >/dev/null 2>&1 ||
    { echo "!! Stack permanente $s nao existe." >&2; exit 1; }
done
for r in users-api catalog-api payments-api; do
  n="$(aws ecr describe-images --repository-name "fcg/$r" --region "$REGION" \
    --query 'length(imageDetails[?imageTags])' --output text)"
  [[ "$n" != "0" ]] || { echo "!! fcg/$r sem imagem com tag no ECR." >&2; exit 1; }
done
# "Limpo" = cluster criado e destruido por este script. Se ja existe, pode ser de um colega.
if aws cloudformation describe-stacks --stack-name "$EKS_STACK" --region "$REGION" >/dev/null 2>&1; then
  echo "!! A stack $EKS_STACK ja existe (alguem esta usando o cluster?). Nada foi alterado." >&2
  exit 1
fi
pass "pre-checagem (conta $account, stacks e imagens)"

# ---------------------------------------------------------------------------
step "1. Subindo o cluster (make cluster-up, 15-20 min)"
cluster_created=1
bash scripts/aws/cluster-up.sh
pass "cluster-up"

step "2. Subindo os workloads (make workloads-deploy)"
bash scripts/aws/deploy-workloads.sh
pass "workloads-deploy"

# ---------------------------------------------------------------------------
step "3. Testes pelo endereco publico"
host=""
for _ in $(seq 1 30); do
  host="$(kubectl get service kong-public -n "$NAMESPACE" \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
  [[ -n "$host" ]] && break
  sleep 10
done
[[ -n "$host" ]] || { fail "NLB sem DNS"; exit 1; }
BASE_URL="http://$host"
echo "   Gateway: $BASE_URL"

# O NLB demora para propagar o DNS e passar no health check dos targets.
code=000
for _ in $(seq 1 40); do
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$BASE_URL/payments/health" || true)"
  [[ "$code" == 2?? ]] && break
  sleep 15
done
if [[ "$code" == 2?? ]]; then pass "GET /payments/health ($code)"; else fail "GET /payments/health ($code)"; exit 1; fi

suffix="$(date +%s)$RANDOM"
ZD_EMAIL="e2e-$suffix@teste.fcg"
ZD_PASSWORD="E2e-${suffix}aA1!"
export ZD_EMAIL ZD_PASSWORD BASE_URL

resp="$(printf '{"name":"E2E %s","email":"%s","password":"%s"}' "$suffix" "$ZD_EMAIL" "$ZD_PASSWORD" |
  curl -s --max-time 15 -w '\n%{http_code}' -H 'Content-Type: application/json' --data @- \
    "$BASE_URL/users/api/users/register" || true)"
code="${resp##*$'\n'}"
user_id="$(printf '%s' "${resp%$'\n'*}" | sed -n 's/.*"id" *: *"\([^"]*\)".*/\1/p')"
if [[ "$code" == 201 && -n "$user_id" ]]; then pass "cadastro de usuario ($code, id $user_id)"; else fail "cadastro de usuario ($code)"; fi

token="$(printf '{"email":"%s","password":"%s"}' "$ZD_EMAIL" "$ZD_PASSWORD" |
  curl -s --max-time 15 -H 'Content-Type: application/json' --data @- \
    "$BASE_URL/users/api/auth/login" | sed -n 's/.*"accessToken" *: *"\([^"]*\)".*/\1/p' || true)"
if [[ -n "$token" ]]; then pass "login (JWT emitido)"; else fail "login"; fi

code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -H "Authorization: Bearer $token" \
  "$BASE_URL/catalog/api/v1/games" || true)"
if [[ "$code" == 2?? ]]; then pass "GET /catalog/api/v1/games com JWT ($code)"; else fail "GET /catalog/api/v1/games ($code)"; fi

# Cadastro -> SNS -> SQS -> Lambda -> DynamoDB (prova do NoSQL).
count=0
if [[ -n "$user_id" ]]; then
  for _ in $(seq 1 12); do
    count="$(aws dynamodb query --table-name "$NOTIFICATIONS_TABLE" --index-name GSI1-UserId \
      --region "$REGION" --key-condition-expression 'UserId = :u' \
      --expression-attribute-values "{\":u\":{\"S\":\"$user_id\"}}" \
      --select COUNT --query Count --output text 2>/dev/null || echo 0)"
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    ((count > 0)) && break
    sleep 10
  done
fi
if ((count > 0)); then pass "notificacao do cadastro no DynamoDB ($count item)"; else fail "notificacao no DynamoDB (nada em 2 min)"; fi

# ---------------------------------------------------------------------------
step "4. Zero downtime: rollout restart de [$ZD_DEPLOYMENTS] com requisicoes em paralelo"
DURATION=1800 bash scripts/aws/zero-downtime-check.sh &
zd_pid=$!
sleep 15
for d in $ZD_DEPLOYMENTS; do
  kubectl -n "$NAMESPACE" rollout restart "deployment/$d"
done
for d in $ZD_DEPLOYMENTS; do
  kubectl -n "$NAMESPACE" rollout status "deployment/$d" --timeout=10m
done
sleep 15   # pega tambem os pods antigos saindo (preStop)
kill -TERM "$zd_pid" 2>/dev/null || true
zd_rc=0
wait "$zd_pid" || zd_rc=$?
zd_pid=""
if ((zd_rc == 0)); then pass "zero downtime durante o rollout"; else fail "zero downtime (houve requisicoes com erro)"; fi
