#!/usr/bin/env bash
# Espera o namespace fcg ficar pronto (Postgres/RabbitMQ demoram para health-check).
#
# Espera por DEPLOYMENT, nao por pod -- e por que isso importa
# ------------------------------------------------------------
# `kubectl wait --for=condition=Ready pods --all` resolve `--all` UMA VEZ, no
# inicio, e depois espera aquela lista fixa de pods. Quando o deploy acabou de
# disparar um rollout (troca de imagem, ConfigMap do Kong, hash dos segredos),
# a lista inclui pods da geracao ANTIGA, que o proprio rollout esta derrubando.
# Eles somem no meio da espera e o comando falha com:
#
#     Error from server (NotFound): pods "users-api-b6b9c8cdf-44x58" not found
#
# Resultado: `make k8s-deploy` terminava com Error 1 e a mensagem "alguns pods
# nao ficaram prontos" logo depois de um deploy PERFEITO -- todos os pods novos
# no ar. Falso negativo, e bem confuso na primeira vez.
#
# `kubectl rollout status` e feito para isso: acompanha a transicao e so volta
# quando a geracao nova esta disponivel, ignorando os pods que estao saindo.
# Os StatefulSets/pods avulsos (se houver) entram na conferencia final.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"

NAMESPACE="fcg"
TIMEOUT="${1:-180s}"

echo "==> Esperando os Deployments do namespace $NAMESPACE (timeout ${TIMEOUT} cada)"

falhou=0
for deploy in $(kubectl get deployments -n "$NAMESPACE" -o jsonpath='{.items[*].metadata.name}'); do
  if kubectl rollout status "deployment/$deploy" -n "$NAMESPACE" --timeout="$TIMEOUT" >/dev/null 2>&1; then
    printf '    [ok]  %s\n' "$deploy"
  else
    printf '    [!!]  %s nao completou o rollout\n' "$deploy"
    falhou=$((falhou + 1))
  fi
done

if [ "$falhou" -gt 0 ]; then
  echo "!! $falhou deployment(s) nao ficaram prontos a tempo. Status atual:" >&2
  kubectl get pods -n "$NAMESPACE"
  exit 1
fi

echo "==> Todos os Deployments estao prontos."
# Pods em Terminating aqui sao os da geracao antiga saindo -- nao sao erro.
kubectl get pods -n "$NAMESPACE"
