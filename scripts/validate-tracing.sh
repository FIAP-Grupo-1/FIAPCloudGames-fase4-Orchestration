#!/usr/bin/env bash
# Valida, ponta a ponta, se o contexto de trace distribuido atravessa o RabbitMQ.
#
# POR QUE ISSO EXISTE
# O agente New Relic .NET nao instrumenta o RabbitMQ.Client 7.x (o wrapper dele
# para em maxVersion="6.8.1"), entao publish/consume nao viram span e o contexto
# NAO viaja sozinho. A correcao e manual, no codigo do catalog-api e do
# payments-api -- ver a secao "Propagacao de trace pelo RabbitMQ" do README.
# Este script e a prova: ele derruba a duvida "sera que o trace atravessa?" para
# um exit code.
#
# COMO FUNCIONA
#   1. Cria duas filas espias, ligadas as mesmas exchanges/routing keys da saga:
#        catalog.exchange  / order.placed    -> compra publicada pelo catalog-api
#        payments.exchange / payment.status  -> resultado publicado pelo payments-api
#      Filas espias sao copias: os consumidores reais continuam recebendo tudo.
#   2. Autentica no gateway e dispara uma compra de verdade.
#   3. Le uma mensagem de cada fila e exige o header `traceparent` (W3C) nas duas,
#      com o MESMO trace-id -- e isso que prova que o contexto atravessou o broker.
#   4. Apaga as filas espias no fim, inclusive quando falha (trap).
#
# USO
#   ./scripts/validate-tracing.sh
#
# Detecta o ambiente sozinho: gateway em :8200 (port-forward do k8s) ou :8000
# (Compose). NAO use :8100 -- aquilo e o listener de status do Kong no Compose e
# responde 404 em rota de aplicacao.
#
# Variaveis de ambiente aceitas (todas opcionais):
#   FCG_EMAIL / FCG_PASSWORD   usuario de teste (default demo@fcg.com / Senha123!)
#   FCG_NAMESPACE              namespace do k8s (default fcg)
#   RABBITMQ_USER / RABBITMQ_PASS   credenciais do broker (default fcg / fcg123)
#   TRACE_TIMEOUT              segundos de espera por cada mensagem (default 60)
#
# Exit codes: 0 = trace atravessou; 1 = nao atravessou ou o ambiente nao permitiu
# concluir nada.
set -uo pipefail

EMAIL="${FCG_EMAIL:-demo@fcg.com}"
PASSWORD="${FCG_PASSWORD:-Senha123!}"
NAMESPACE="${FCG_NAMESPACE:-fcg}"
RMQ_USER="${RABBITMQ_USER:-fcg}"
RMQ_PASS="${RABBITMQ_PASS:-fcg123}"
TIMEOUT="${TRACE_TIMEOUT:-60}"
BODY_FILE=""

SPY_ORDER="trace-spy.order-placed"
SPY_PAYMENT="trace-spy.payment-status"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ---------------------------------------------------------------- saida bonita
if [ -t 1 ]; then C_OK=$'\033[32m'; C_ERR=$'\033[31m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else C_OK=""; C_ERR=""; C_DIM=""; C_OFF=""; fi

step() { printf '\n== %s\n' "$*"; }
info() { printf '   %s%s%s\n' "$C_DIM" "$*" "$C_OFF"; }
ok()   { printf '   %sOK%s   %s\n' "$C_OK" "$C_OFF" "$*"; }
die()  { printf '\n%sFALHOU%s  %s\n' "$C_ERR" "$C_OFF" "$*" >&2; exit 1; }

for bin in curl jq; do
  command -v "$bin" >/dev/null 2>&1 || die "'$bin' nao esta instalado -- o script precisa dele."
done

# -------------------------------------------------- 1. qual ambiente esta no ar
step "Ambiente"
GATEWAY=""
for port in 8200 8000; do
  code="$(curl -s --max-time 3 -o /dev/null -w '%{http_code}' "http://localhost:$port/payments/health" 2>/dev/null || true)"
  if [ "$code" = "200" ]; then GATEWAY="http://localhost:$port"; break; fi
done
[ -n "$GATEWAY" ] || die $'nenhum gateway respondeu.\n         k8s     : kubectl port-forward service/kong-proxy 8200:8000 -n '"$NAMESPACE"$'\n         Compose : make up'

if [ "$GATEWAY" = "http://localhost:8200" ]; then
  MODE="Kubernetes"
  command -v kubectl >/dev/null 2>&1 || die "gateway em :8200 (k8s) mas 'kubectl' nao esta no PATH."
  RMQ_EXEC=(kubectl exec -n "$NAMESPACE" deploy/rabbitmq --)
else
  MODE="Docker Compose"
  command -v docker >/dev/null 2>&1 || die "gateway em :8000 (Compose) mas 'docker' nao esta no PATH."
  RMQ_EXEC=(docker compose -f "$ROOT_DIR/docker-compose.yml" exec -T rabbitmq)
fi
info "$MODE -- gateway em $GATEWAY"

rmq() { "${RMQ_EXEC[@]}" rabbitmqadmin -u "$RMQ_USER" -p "$RMQ_PASS" "$@" 2>/dev/null; }

rmq list exchanges name >/dev/null 2>&1 \
  || die "nao consegui falar com o rabbitmqadmin ($MODE). O broker esta de pe?"
ok "broker acessivel"

# ------------------------------------------------------------ 2. filas espias
# Nomes fixos (nao aleatorios) de proposito: assim uma execucao anterior que tenha
# morrido de forma feia deixa no maximo DUAS filas conhecidas, e a proxima execucao
# as remove aqui antes de declarar. E isso que torna o script idempotente.
drop_spies() {
  rmq delete queue name="$SPY_ORDER"   >/dev/null 2>&1 || true
  rmq delete queue name="$SPY_PAYMENT" >/dev/null 2>&1 || true
}

cleanup() {
  local rc=$?
  trap - EXIT INT TERM
  drop_spies
  [ -n "$BODY_FILE" ] && rm -f "$BODY_FILE"
  exit "$rc"
}

step "Filas espias"
drop_spies
trap cleanup EXIT INT TERM

declare_spy() { # <fila> <exchange> <routing_key>
  rmq declare queue name="$1" durable=false auto_delete=false >/dev/null \
    || die "nao consegui declarar a fila espia '$1'."
  rmq declare binding source="$2" destination="$1" routing_key="$3" >/dev/null \
    || die "nao consegui ligar '$1' em $2/$3 (a exchange existe?)."
  info "$1  <-  $2 / $3"
}

declare_spy "$SPY_ORDER"   "catalog.exchange"  "order.placed"
declare_spy "$SPY_PAYMENT" "payments.exchange" "payment.status"
ok "duas filas espias no ar (serao removidas no fim, mesmo se der erro)"

# ------------------------------------------------------------ 3. autenticacao
# Token novo em toda execucao, de proposito: o JWT dura ~1h e um token vencido faz
# o Kong devolver 401 -- a requisicao nem chega no catalog-api e nao ha o que
# validar. Reaproveitar o token de ~/.fcg-demo economizaria um request e custaria
# um falso negativo.
step "Autenticacao"
api_login() {
  curl -s --max-time 20 -X POST "$GATEWAY/users/api/auth/login" \
    -H 'Content-Type: application/json' \
    -d "{\"email\":\"$EMAIL\",\"password\":\"$PASSWORD\"}" | jq -r '.accessToken // empty'
}

TOKEN="$(api_login)"
if [ -z "$TOKEN" ]; then
  info "usuario $EMAIL nao existe (ou senha mudou) -- registrando"
  curl -s --max-time 60 -o /dev/null -X POST "$GATEWAY/users/api/users/register" \
    -H 'Content-Type: application/json' \
    -d "{\"name\":\"Trace Validator\",\"email\":\"$EMAIL\",\"password\":\"$PASSWORD\"}" || true
  TOKEN="$(api_login)"
fi
[ -n "$TOKEN" ] || die "nao consegui autenticar em $GATEWAY como $EMAIL."
ok "autenticado como $EMAIL"

auth_get() { curl -s --max-time 25 "$GATEWAY$1" -H "Authorization: Bearer $TOKEN"; }

# --------------------------------------------------------- 4. jogo para comprar
step "Escolhendo um jogo"
pick_game() { # -> "<id>\t<titulo>" de um jogo que a biblioteca ainda nao tem
  local owned games
  owned="$(auth_get /catalog/api/v1/library | jq -c '[.library.games[]?.gameId]')"
  games="$(auth_get /catalog/api/v1/games)"
  jq -r --argjson o "${owned:-[]}" 'first(.data.games[]? | select(.id as $i | ($o | index($i)) == null) | "\(.id)\t\(.title)")' <<<"$games"
}

create_game() { # -> "<id>\t<titulo>" de um jogo novinho, garantidamente nao comprado
  local created id title
  created="$(curl -s --max-time 25 -X POST "$GATEWAY/catalog/api/v1/games" \
    -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
    -d "{\"title\":\"Trace Probe $(date +%s)\",\"description\":\"Jogo criado pelo validate-tracing.sh\",\"price\":9.90,\"genre\":1,\"releaseDate\":\"2027-01-01\"}")"
  # O id sai da propria resposta do POST. Listar de novo nao adianta: criar um jogo
  # NAO invalida a chave de cache da lista (games:all:...), entao o jogo novo so
  # apareceria la depois do TTL. Ja custou um "nao encontrei jogo disponivel".
  id="$(jq -r '.game.id // empty' <<<"$created")"
  title="$(jq -r '.game.title // empty' <<<"$created")"
  [ -n "$id" ] || die "nao consegui criar um jogo para comprar. Resposta: $(head -c 400 <<<"$created")"
  printf '%s\t%s' "$id" "$title"
}

GAME="$(pick_game)"
if [ -z "$GAME" ]; then
  info "todo o catalogo visivel ja esta na biblioteca -- criando um jogo novo"
  GAME="$(create_game)"
fi
GAME_ID="${GAME%%$'\t'*}"
GAME_TITLE="${GAME#*$'\t'}"
ok "$GAME_TITLE ($GAME_ID)"

# ------------------------------------------------------------- 5. a compra
BODY_FILE="$(mktemp)"
buy() { # <game-id> -> imprime o status HTTP
  curl -s --max-time 30 -o "$BODY_FILE" -w '%{http_code}' \
    -X POST "$GATEWAY/catalog/api/v1/library/add" \
    -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
    -d "{\"gameId\":\"$1\"}"
}

step "Disparando a compra"
HTTP_CODE="$(buy "$GAME_ID")"

# 409 aqui quase sempre e cache: a leitura da biblioteca tambem passa pelo Redis, e
# um jogo comprado ha pouco pode nao aparecer nela ainda -- o pick_game o considera
# disponivel e o catalog-api discorda. Um jogo recem-criado nao tem esse problema.
if [ "$HTTP_CODE" = "409" ]; then
  info "409 (biblioteca lida do cache estava defasada) -- criando um jogo novo e tentando de novo"
  GAME="$(create_game)"
  GAME_ID="${GAME%%$'\t'*}"
  GAME_TITLE="${GAME#*$'\t'}"
  info "$GAME_TITLE ($GAME_ID)"
  HTTP_CODE="$(buy "$GAME_ID")"
fi

# Sem 202 nao ha mensagem publicada, e qualquer conclusao sobre headers seria
# chute. 401 aqui = Kong barrou o token e o request nem chegou no servico.
if [ "$HTTP_CODE" != "202" ]; then
  info "resposta: $(head -c 400 "$BODY_FILE")"
  case "$HTTP_CODE" in
    401) die "a compra devolveu 401 -- o Kong barrou o token. A requisicao nao chegou no catalog-api." ;;
    409) die "a compra devolveu 409 mesmo com um jogo recem-criado -- algo alem do cache esta errado." ;;
    *)   die "a compra devolveu $HTTP_CODE (esperado 202). Nada foi publicado; nao da para validar o trace." ;;
  esac
fi
ok "202 Accepted -- a saga comecou"

# ------------------------------------------- 6. as mensagens e os headers delas
wait_message() { # <fila> -> imprime o JSON da mensagem
  local queue="$1" deadline=$(( SECONDS + TIMEOUT )) out
  while [ "$SECONDS" -lt "$deadline" ]; do
    out="$(rmq --format=raw_json get queue="$queue" count=1 ackmode=ack_requeue_false || true)"
    if [ -n "$out" ] && [ "$(jq 'length' <<<"$out" 2>/dev/null || echo 0)" -gt 0 ]; then
      printf '%s' "$out"; return 0
    fi
    sleep 1
  done
  return 1
}

FAILURES=0
report_missing() { # <rotulo> <headers-json>
  printf '\n   %sSEM traceparent%s  %s\n' "$C_ERR" "$C_OFF" "$1"
  printf '   headers recebidos: %s\n' "$2"
  FAILURES=$(( FAILURES + 1 ))
}

extract_trace_id() { cut -d- -f2 <<<"$1"; }

step "Esperando as mensagens (ate ${TIMEOUT}s cada)"

MSG_ORDER="$(wait_message "$SPY_ORDER")" \
  || die "nenhuma mensagem em $SPY_ORDER apos ${TIMEOUT}s. O catalog-api publicou o OrderPlacedEvent?"
ok "catalog.exchange / order.placed recebida"

MSG_PAYMENT="$(wait_message "$SPY_PAYMENT")" \
  || die "nenhuma mensagem em $SPY_PAYMENT apos ${TIMEOUT}s. O payments-api consumiu e respondeu?"
ok "payments.exchange / payment.status recebida"

step "Conferindo o traceparent"
TP_RE='^00-[0-9a-f]{32}-[0-9a-f]{16}-[0-9a-f]{2}$'

HDR_ORDER="$(jq -c '.[0].properties.headers // {}' <<<"$MSG_ORDER")"
HDR_PAYMENT="$(jq -c '.[0].properties.headers // {}' <<<"$MSG_PAYMENT")"
TP_ORDER="$(jq -r '.[0].properties.headers.traceparent // empty' <<<"$MSG_ORDER")"
TP_PAYMENT="$(jq -r '.[0].properties.headers.traceparent // empty' <<<"$MSG_PAYMENT")"

if [ -z "$TP_ORDER" ]; then
  report_missing "catalog.exchange / order.placed  (publicado pelo catalog-api)" "$HDR_ORDER"
elif ! [[ "$TP_ORDER" =~ $TP_RE ]]; then
  printf '\n   %straceparent malformado%s  order.placed: %s\n' "$C_ERR" "$C_OFF" "$TP_ORDER"
  FAILURES=$(( FAILURES + 1 ))
else
  ok "order.placed    traceparent=$TP_ORDER"
fi

if [ -z "$TP_PAYMENT" ]; then
  report_missing "payments.exchange / payment.status  (publicado pelo payments-api)" "$HDR_PAYMENT"
elif ! [[ "$TP_PAYMENT" =~ $TP_RE ]]; then
  printf '\n   %straceparent malformado%s  payment.status: %s\n' "$C_ERR" "$C_OFF" "$TP_PAYMENT"
  FAILURES=$(( FAILURES + 1 ))
else
  ok "payment.status  traceparent=$TP_PAYMENT"
fi

# O trace-id igual nas duas pontas e o que separa "cada servico gerou um trace
# proprio" de "o contexto atravessou o broker".
if [ -n "$TP_ORDER" ] && [ -n "$TP_PAYMENT" ]; then
  ID_ORDER="$(extract_trace_id "$TP_ORDER")"
  ID_PAYMENT="$(extract_trace_id "$TP_PAYMENT")"
  if [ "$ID_ORDER" = "$ID_PAYMENT" ]; then
    ok "mesmo trace-id nas duas pontas ($ID_ORDER)"
  else
    printf '\n   %sTRACES DIFERENTES%s  catalog=%s  payments=%s\n' "$C_ERR" "$C_OFF" "$ID_ORDER" "$ID_PAYMENT"
    printf '   O payments-api nao aceitou o contexto recebido (AcceptDistributedTraceHeaders).\n'
    FAILURES=$(( FAILURES + 1 ))
  fi
fi

# ----------------------------------------------------------------- veredito
if [ "$FAILURES" -gt 0 ]; then
  cat >&2 <<EOF

${C_ERR}O trace NAO atravessa o RabbitMQ.${C_OFF}

Causa conhecida: o agente New Relic .NET instrumenta RabbitMQ.Client so ate a
6.8.1 e o projeto usa a 7.2.1, entao nada e propagado automaticamente. A
correcao e manual, no codigo dos servicos:

  - catalog-api  : InsertDistributedTraceHeaders  ao publicar OrderPlacedEvent
  - payments-api : AcceptDistributedTraceHeaders  ao consumir (com [Transaction]),
                   e InsertDistributedTraceHeaders ao publicar PaymentProcessedEvent
  - os dois      : FiapCloudGames.RabbitMq >= 1.1.0 (e a versao que expoe headers)

Detalhes e alternativas descartadas: secao "Propagacao de trace pelo RabbitMQ"
do README.md.
EOF
  exit 1
fi

printf '\n%sTrace propagado ponta a ponta pelo broker.%s  catalog-api -> RabbitMQ -> payments-api -> RabbitMQ\n' "$C_OK" "$C_OFF"
exit 0
