# Imagem LOCAL do NotificationsAPI: o mesmo codigo da Lambda de producao, rodando
# na imagem base oficial da AWS, que ja traz o Runtime Interface Emulator (RIE).
#
# O RIE expoe a API de invocacao da Lambda em HTTP:
#   POST http://<container>:8080/2015-03-31/functions/function/invocations
# e e isso que o Kong chama localmente. Na AWS nada disto existe: la a funcao e
# acionada pelo SQS, e o deploy continua sendo `sam deploy` no repo do
# NotificationsAPI. Este arquivo mora no repo de orquestracao justamente para
# nao tocar em nada daquele repo.
#
# Contexto de build: esta pasta (notifications-local/). O codigo entra pelo
# contexto nomeado `notificationsapi`, que aponta para a pasta NotificationsAPI/
# do repo irmao (solucao + Directory.Build.props):
#   Compose: build.additional_contexts no docker-compose.yml
#   k8s:     --build-context no scripts/k8s/build-images.sh
#   a mao:   docker build --build-context notificationsapi=../FIAPCloudGames-fase3-NotificationsAPI/NotificationsAPI \
#              -t fcg/notifications-lambda:local notifications-local
#
# Uma imagem, duas funcoes: o handler e escolhido pelo `command` de cada
# container, igual ao `Handler:` de cada funcao no template.yaml.

FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src
# O .dockerignore da pasta NotificationsAPI/ vale tambem para o contexto nomeado:
# bin/ e obj/ do host ficam de fora (o contexto transferido e so o fonte).
COPY --from=notificationsapi . .
RUN dotnet publish src/Notifications.Functions/Notifications.Functions.csproj \
      -c Release -o /out --nologo

FROM public.ecr.aws/lambda/dotnet:10
COPY --from=build /out ${LAMBDA_TASK_ROOT}
CMD ["Notifications.Functions::Notifications.Functions.Functions::UserRegisteredHandler"]
