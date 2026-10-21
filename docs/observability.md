# Observabilidade

## Objetivo

A solução utiliza New Relic para monitoramento dos microsserviços.

## Serviços monitorados

- FIAPCloudGames-fase3-UsersAPI
- FIAPCloudGames-fase3-CatalogAPI
- FIAPCloudGames-fase3-PaymentsAPI
- FIAPCloudGames-fase3-NotificationsAPI

## APM

O New Relic .NET Agent é utilizado para instrumentação automática
das aplicações ASP.NET Core.

A instrumentação automática cobre HTTP, Postgres e Redis. Ela **não** cobre
o RabbitMQ: o wrapper do agente casa apenas até o `RabbitMQ.Client` 6.8.1 e o
projeto usa a 7.2.1. Ver a seção abaixo.

## Métricas

São coletadas métricas relacionadas a:

- throughput;
- tempo de resposta;
- erros;
- transações;
- desempenho das aplicações.

## Logs

Os logs das aplicações são encaminhados ao New Relic,
permitindo análise em conjunto com os traces.

## Distributed Tracing

O trace começa na requisição HTTP do CatalogAPI — o Kong não roda agente .NET
e por isso não aparece como span.

O fluxo de compra atravessa o RabbitMQ até o PaymentsAPI e volta, mas **essa
propagação não é automática**: o agente não instrumenta o `RabbitMQ.Client` 7.x,
então o contexto é injetado e aceito manualmente no código do CatalogAPI e do
PaymentsAPI (`InsertDistributedTraceHeaders` / `AcceptDistributedTraceHeaders`,
com `TransportType.Queue`). Sem essa correção deployada, cada serviço aparece
como um trace isolado.

Causa, alternativas descartadas e o procedimento de validação estão no
[README do repositório de orquestração](../README.md#propagação-de-trace-pelo-rabbitmq).

## Configuração

A chave de licença é fornecida através da variável:

NEW_RELIC_LICENSE_KEY

A chave não é armazenada no código-fonte.

## Validação

Para validar a solução:

1. iniciar os serviços;
2. executar uma consulta no CatalogAPI;
3. executar uma compra;
4. verificar APM;
5. verificar logs;
6. verificar traces;
7. verificar o trace distribuído entre CatalogAPI e PaymentsAPI.

O passo 7 é automatizável — e não depende de olhar a UI:

    ./scripts/validate-tracing.sh

O script dispara uma compra real e falha se o header `traceparent` não chegar
às duas exchanges da saga com o mesmo trace-id.
