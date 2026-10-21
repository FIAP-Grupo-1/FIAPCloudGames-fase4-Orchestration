#!/usr/bin/env bash
# Builda as imagens Docker das 3 APIs e da Lambda local do NotificationsAPI
# e carrega no Minikube.
# Le os caminhos dos repos irmaos do .env (mesmas variaveis do docker-compose).
#
# ----------------------------------------------------------------------
# A ARMADILHA QUE ESTE SCRIPT RESOLVE (leia antes de simplificar)
# ----------------------------------------------------------------------
# `minikube image load fcg/users-api:1.0` NAO sobrescreve uma tag que ja existe
# no cluster quando um container esta usando aquela imagem: o comando termina
# com SUCESSO, sem aviso, e o cluster continua rodando a imagem antiga.
#
# Somado ao `imagePullPolicy: IfNotPresent` e a uma tag fixa (`:1.0`), isso cria
# um `make k8s-up` que parece funcionar e nao muda nada: o `kubectl apply` nao
# altera o pod spec (a tag e a mesma), entao nem ha rollout.
#
# Sintoma real que isso ja causou: o users-api seguiu rodando um build antigo,
# de antes da claim `iss` existir, e TODA chamada autenticada pelo gateway
# voltava `401 {"message":"No mandatory 'iss' in claims"}` -- com o codigo-fonte,
# o manifesto e a config do Kong todos corretos.
#
# Por isso, para cada servico, comparamos o ID da imagem no host com o ID no
# cluster e, se divergirem, derrubamos os pods (a tag so pode ser trocada quando
# nenhum container a usa), trocamos a imagem e subimos de novo.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

if [ -f "$ROOT_DIR/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  source "$ROOT_DIR/.env"
  set +a
fi

USERS_API_PATH="${USERS_API_PATH:-../FIAPCloudGames-fase3-UsersAPI}"
CATALOG_API_PATH="${CATALOG_API_PATH:-../FIAPCloudGames-fase3-CatalogAPI}"
PAYMENTS_API_PATH="${PAYMENTS_API_PATH:-../FIAPCloudGames-fase3-PaymentsAPI}"
NOTIFICATIONS_API_PATH="${NOTIFICATIONS_API_PATH:-../FIAPCloudGames-fase3-NotificationsAPI}"

cd "$ROOT_DIR"

NAMESPACE="fcg"

# imagem | contexto | Dockerfile | Deployments que usam a imagem | contexto nomeado
#
# A `notifications-lambda` e SOMENTE LOCAL. Em producao o NotificationsAPI e uma
# Lambda (deploy via `sam deploy` no repo dele); aqui o mesmo codigo roda na
# imagem oficial da Lambda, com o Runtime Interface Emulator, para o Kong poder
# invoca-lo. O Dockerfile mora neste repo (notifications-local/) e le o codigo do
# repo irmao por um contexto nomeado -- nada e escrito la. Uma imagem atende as
# duas funcoes (o handler vem do `args` de cada Deployment), dai a lista.
SERVICES=(
  "users-api|$USERS_API_PATH|$USERS_API_PATH/src/FCG.API/Dockerfile|users-api|"
  "catalog-api|$CATALOG_API_PATH|$CATALOG_API_PATH/src/CatalogAPI.API/Dockerfile|catalog-api|"
  "payments-api|$PAYMENTS_API_PATH|$PAYMENTS_API_PATH/src/FCG.API/Dockerfile|payments-api|"
  "notifications-lambda|notifications-local|notifications-local/Dockerfile|notifications-user-registered,notifications-payment-processed|notificationsapi=$NOTIFICATIONS_API_PATH/NotificationsAPI"
)

# Impressao digital do CONTEUDO da imagem (hash dos digests das camadas do rootfs).
#
# Por que nao comparar o ID da imagem, como antes
# -----------------------------------------------
# O Docker do host usa o image store do containerd e reporta como ID o digest do
# MANIFESTO; o Docker de dentro do Minikube usa o driver classico e reporta o
# digest do CONFIG. Sao numeros diferentes para a MESMA imagem, entao a conferencia
# por ID acusava divergencia em todos os servicos mesmo com o load correto --
# `make k8s-up` abortava antes do deploy, sem nada de errado no cluster.
#
# `.RootFS.Layers` e enderecado por conteudo e identico dos dois lados: se as
# camadas batem, o cluster tem exatamente a imagem que o host acabou de buildar.
image_fingerprint() {
  printf '%s' "$1" | sha256sum | cut -c1-12
}

host_image_id() {
  local layers
  layers="$(docker inspect --format '{{.RootFS.Layers}}' "$1" 2>/dev/null)" || return 0
  [ -n "$layers" ] && image_fingerprint "$layers"
}

cluster_image_id() {
  local layers
  layers="$(minikube ssh -- "docker inspect --format '{{.RootFS.Layers}}' $1" 2>/dev/null | tr -d '\r')" || return 0
  [ -n "$layers" ] && image_fingerprint "$layers"
}

total="${#SERVICES[@]}"
i=0
SKIPPED=()

for entry in "${SERVICES[@]}"; do
  i=$((i + 1))
  IFS='|' read -r name ctx dockerfile deployments named_ctx <<< "$entry"
  image="fcg/$name:1.0"

  echo "==> [$i/$total] $name"

  # Um repo de servico pode ter sido reestruturado e nao ter mais o Dockerfile
  # neste caminho. Sem esta checagem, o `set -e` mataria o script no meio e os
  # servicos seguintes (e a conferencia final) nunca rodariam.
  if [ ! -f "$dockerfile" ]; then
    echo "    [skip] Dockerfile nao encontrado em $dockerfile" >&2
    echo "           o repo do $name provavelmente foi reestruturado." >&2
    SKIPPED+=("$name")
    continue
  fi

  # Contexto nomeado: o codigo vem de outra pasta que nao o contexto do build.
  # Mesma protecao do Dockerfile ausente, para o repo irmao nao clonado.
  build_args=()
  if [ -n "$named_ctx" ]; then
    if [ ! -d "${named_ctx#*=}" ]; then
      echo "    [skip] codigo-fonte nao encontrado em ${named_ctx#*=}" >&2
      echo "           confira o caminho do repo no .env." >&2
      SKIPPED+=("$name")
      continue
    fi
    build_args=(--build-context "$named_ctx")
  fi

  docker build -t "$image" ${build_args[@]+"${build_args[@]}"} -f "$dockerfile" "$ctx"

  host_id="$(host_image_id "$image")"
  cluster_id="$(cluster_image_id "$image")"

  if [ -n "$cluster_id" ] && [ "$host_id" = "$cluster_id" ]; then
    echo "    imagem do cluster ja e identica a do host (${host_id}) - nada a fazer"
    continue
  fi

  # A tag no cluster esta ausente ou desatualizada. Se ha Deployments de pe, eles
  # precisam sair do ar para a tag ficar livre (docker nao remove imagem em uso).
  # Uma imagem pode servir a mais de um Deployment -- TODOS precisam escalar.
  # (Arrays indexados, sem associativos: o bash 3.2 do macOS nao os tem.)
  scaled_deploys=()
  scaled_replicas=()
  IFS=',' read -r -a deploys <<< "$deployments"
  for d in "${deploys[@]}"; do
    if kubectl get deployment "$d" -n "$NAMESPACE" >/dev/null 2>&1; then
      scaled_deploys+=("$d")
      scaled_replicas+=("$(kubectl get deployment "$d" -n "$NAMESPACE" -o jsonpath='{.spec.replicas}')")
    fi
  done

  if [ "${#scaled_deploys[@]}" -gt 0 ]; then
    echo "    imagem do cluster desatualizada; escalando ${scaled_deploys[*]} para 0 para liberar a tag"
    for d in "${scaled_deploys[@]}"; do
      kubectl scale deployment/"$d" --replicas=0 -n "$NAMESPACE" >/dev/null
    done
    for d in "${scaled_deploys[@]}"; do
      kubectl wait --for=delete pod -l app="$d" -n "$NAMESPACE" --timeout=120s >/dev/null 2>&1 || true
    done
  fi

  minikube image rm "$image" >/dev/null 2>&1 || true
  minikube image load "$image"

  if [ "${#scaled_deploys[@]}" -gt 0 ]; then
    j=0
    while [ "$j" -lt "${#scaled_deploys[@]}" ]; do
      echo "    voltando ${scaled_deploys[$j]} para ${scaled_replicas[$j]} replica(s) com a imagem nova"
      kubectl scale deployment/"${scaled_deploys[$j]}" --replicas="${scaled_replicas[$j]}" -n "$NAMESPACE" >/dev/null
      j=$((j + 1))
    done
  fi
done

# Cinto de seguranca: um "load" que nao pegou passa desapercebido, entao
# conferimos explicitamente e falhamos alto se o cluster ficou defasado.
echo "==> Conferindo se o cluster ficou com as imagens do host"
divergentes=0
for entry in "${SERVICES[@]}"; do
  IFS='|' read -r name _ _ _ _ <<< "$entry"
  image="fcg/$name:1.0"
  host_id="$(host_image_id "$image")"
  cluster_id="$(cluster_image_id "$image")"

  # Servico sem Dockerfile: nao foi rebuildado agora. O cluster segue com a
  # imagem carregada em algum build anterior - dizemos isso em voz alta.
  if [[ " ${SKIPPED[*]-} " == *" $name "* ]]; then
    if [ -n "$cluster_id" ]; then
      printf '    [skip] %-20s sem Dockerfile; cluster mantem %s (build anterior)\n' "$name" "${cluster_id}"
    else
      printf '    [!!]  %-20s sem Dockerfile e sem imagem no cluster\n' "$name"
      divergentes=$((divergentes + 1))
    fi
    continue
  fi

  if [ "$host_id" = "$cluster_id" ]; then
    printf '    [ok]  %-20s %s\n' "$name" "${host_id}"
  else
    printf '    [!!]  %-20s host=%s cluster=%s\n' "$name" "${host_id}" "${cluster_id}"
    divergentes=$((divergentes + 1))
  fi
done

if [ "$divergentes" -gt 0 ]; then
  echo "!! $divergentes imagem(ns) do cluster nao confere(m) com o host." >&2
  echo "   Os pods rodariam codigo antigo. Verifique se o minikube esta de pe e rode de novo." >&2
  exit 1
fi

# `${#SKIPPED[@]-0}` e sintaxe invalida ("bad substitution") e derrubava o
# script aqui, no fim de TODO build bem-sucedido -- o que fazia o `make k8s-up`
# parar antes do deploy. `${SKIPPED[*]-}` sozinho ja cobre o array vazio, inclusive
# com `set -u` no bash 3.2 do macOS.
if [ -n "${SKIPPED[*]-}" ]; then
  echo "!! Sem Dockerfile, nao rebuildado(s): ${SKIPPED[*]}" >&2
  echo "   O cluster continua com a imagem de um build anterior desses servicos." >&2
fi

echo "==> Imagens buildadas e carregadas no Minikube."
