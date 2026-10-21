#!/bin/sh
# Cria a tabela fcg-notifications no DynamoDB Local, se ela ainda nao existir.
#
# SOMENTE LOCAL. Na AWS a tabela e provisionada pelo template.yaml (SAM) do repo
# do NotificationsAPI; o schema abaixo espelha aquele -- chave PK, PAY_PER_REQUEST
# e o indice GSI1-UserId -- igual ao fixture dos testes de integracao daquele repo
# (tests/.../DynamoDb/DynamoDbTable.cs). Se o schema mudar la, mude aqui.
#
# Roda na imagem amazon/aws-cli. Idempotente: pode rodar a cada subida.
# Com --keep-alive, fica de pe depois de criar a tabela (uso como sidecar no k8s,
# onde o container precisa continuar rodando para o pod ficar Ready).
set -eu

ENDPOINT="${DYNAMODB_ENDPOINT:-http://notifications-dynamodb:8000}"
TABLE="${DYNAMODB_TABLE:-fcg-notifications}"

# O DynamoDB Local roda com -sharedDb, entao as credenciais sao ignoradas --
# mas o CLI se recusa a chamar sem alguma.
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-local}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-local}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
export AWS_PAGER=""

tentativas=0
until aws dynamodb list-tables --endpoint-url "$ENDPOINT" >/dev/null 2>&1; do
  tentativas=$((tentativas + 1))
  if [ "$tentativas" -ge 60 ]; then
    echo "DynamoDB Local nao respondeu em $ENDPOINT apos 60s" >&2
    exit 1
  fi
  sleep 1
done

if aws dynamodb describe-table --table-name "$TABLE" --endpoint-url "$ENDPOINT" >/dev/null 2>&1; then
  echo "tabela $TABLE ja existe em $ENDPOINT"
else
  aws dynamodb create-table \
    --endpoint-url "$ENDPOINT" \
    --table-name "$TABLE" \
    --billing-mode PAY_PER_REQUEST \
    --attribute-definitions \
        AttributeName=PK,AttributeType=S \
        AttributeName=UserId,AttributeType=S \
        AttributeName=CreatedAt,AttributeType=S \
    --key-schema AttributeName=PK,KeyType=HASH \
    --global-secondary-indexes \
        '[{"IndexName":"GSI1-UserId","KeySchema":[{"AttributeName":"UserId","KeyType":"HASH"},{"AttributeName":"CreatedAt","KeyType":"RANGE"}],"Projection":{"ProjectionType":"ALL"}}]' \
    >/dev/null
  echo "tabela $TABLE criada em $ENDPOINT"
fi

if [ "${1:-}" = "--keep-alive" ]; then
  exec tail -f /dev/null
fi
