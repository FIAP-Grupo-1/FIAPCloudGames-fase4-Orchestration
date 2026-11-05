#!/usr/bin/env bash
# Prova de zero downtime para o video: faz requisicoes em loop no endereco publico
# (NLB -> Kong -> API) enquanto um rollout acontece, e conta quantas falharam.
#
# Uso (em um terminal, antes de disparar a pipeline ou o `kubectl set image`):
#   ZD_EMAIL=... ZD_PASSWORD=... make zero-downtime-check
# Em outro terminal:  kubectl get pods -n fcg -w
#
# Variaveis (todas opcionais):
#   BASE_URL     endereco do gateway; padrao: DNS do NLB do service kong-public
#   ZD_EMAIL / ZD_PASSWORD  usuario de teste ja cadastrado; o script faz login uma vez
#                e usa o JWT. Nunca grave esses valores no repositorio.
#   ZD_TOKEN     JWT pronto (alternativa ao e-mail/senha)
#   ZD_PATH      rota testada; padrao /catalog/api/v1/games com token, ou
#                /payments/health sem token (a unica rota anonima que chega a uma API)
#   DURATION     segundos de teste (padrao 180; Ctrl+C encerra antes e mostra o resumo)
#   INTERVAL     segundos entre requisicoes (padrao 1). O Kong limita 120 req/min por
#                cliente (k8s/03-kong-config.yaml), entao nao desca muito abaixo de 0.5.
#
# Resultado: 2xx = ok; 429 = rate limit do Kong (nao e queda, mas aumente o INTERVAL);
# qualquer outro codigo, ou 000 (sem resposta/timeout), conta como erro.
# Sai com codigo 1 se houve erro.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../k8s/common.sh"

NAMESPACE="${NAMESPACE:-fcg}"
DURATION="${DURATION:-180}"
INTERVAL="${INTERVAL:-1}"

if [[ -z "${BASE_URL:-}" ]]; then
  host="$(kubectl get service kong-public -n "$NAMESPACE" \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
  if [[ -z "$host" ]]; then
    echo "!! NLB sem DNS. Rode 'make workloads-deploy' ou informe BASE_URL=http://..." >&2
    exit 1
  fi
  BASE_URL="http://$host"
fi
BASE_URL="${BASE_URL%/}"

token="${ZD_TOKEN:-}"
if [[ -z "$token" && -n "${ZD_EMAIL:-}" && -n "${ZD_PASSWORD:-}" ]]; then
  # Corpo pelo stdin: a senha nao aparece na lista de processos (ps).
  # Aspas e barras na senha quebrariam o JSON montado aqui; use uma senha sem elas.
  resp="$(printf '{"email":"%s","password":"%s"}' "$ZD_EMAIL" "$ZD_PASSWORD" |
    curl -sS --max-time 10 -H 'Content-Type: application/json' --data @- \
      "$BASE_URL/users/api/auth/login" || true)"
  token="$(printf '%s' "$resp" | sed -n 's/.*"accessToken" *: *"\([^"]*\)".*/\1/p')"
  if [[ -z "$token" ]]; then
    echo "!! Login falhou (o usuario existe? confira em /users/api/users/register)." >&2
    exit 1
  fi
fi

if [[ -n "$token" ]]; then
  ZD_PATH="${ZD_PATH:-/catalog/api/v1/games}"
  auth=(-H "Authorization: Bearer $token")
else
  ZD_PATH="${ZD_PATH:-/payments/health}"
  auth=()
  echo "   Sem token: testando so $ZD_PATH. Rotas com JWT dariam 401 no Kong sem chegar a API."
fi

url="$BASE_URL$ZD_PATH"
ok=0 limited=0 errors=0 total=0
start=$SECONDS

summary() {
  echo
  echo "==> Resumo: $total requisicoes em $((SECONDS - start))s em $url"
  echo "    ok (2xx): $ok | rate limit (429): $limited | erros: $errors"
  if ((errors == 0 && ok > 0)); then
    echo "    ZERO DOWNTIME: nenhuma requisicao falhou."
  else
    echo "    Houve falhas: veja as linhas marcadas com ERRO acima."
  fi
}
trap 'summary; exit $(( errors > 0 ? 1 : 0 ))' INT

echo "==> Testando $url por ${DURATION}s (1 requisicao a cada ${INTERVAL}s). Ctrl+C encerra."
while ((SECONDS - start < DURATION)); do
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "${auth[@]}" "$url" || true)"
  total=$((total + 1))
  case "$code" in
    2??) ok=$((ok + 1)) ;;
    429) limited=$((limited + 1)); echo "$(date +%T) 429 rate limit (aumente INTERVAL)" ;;
    *) errors=$((errors + 1)); echo "$(date +%T) ERRO http=$code" ;;
  esac
  ((total % 20 == 0)) && echo "$(date +%T) $total requisicoes | ok=$ok erros=$errors"
  sleep "$INTERVAL"
done

summary
((errors == 0))
