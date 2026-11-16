#!/usr/bin/env bash
# Cadastra ~20 jogos de demonstração no catálogo, pelo gateway (Kong), para o vídeo e para
# testar a busca. O Postgres nasce vazio a cada cluster-up e o seed de carga do k6
# (performance/seed-games.sh no CatalogAPI) só cria "Jogo de carga N", que não serve para
# mostrar fuzzy e relevância.
#
# Cada jogo criado também entra no índice de busca (OpenSearch) na hora.
#
# Uso:
#   make seed-demo                                   # EKS: NLB do kong-public + admin do Secrets Manager
#   BASE_URL=http://localhost:8000 SEED_PASSWORD=... make seed-demo   # docker compose (senha = ADMIN_PASSWORD do .env)
#
# Variáveis (todas opcionais):
#   BASE_URL       gateway; padrão: DNS do NLB do service kong-public (EKS) ou http://localhost:8000
#   SEED_EMAIL     usuário que faz login; padrão admin@fcg.com (admin raiz do users-api)
#   SEED_PASSWORD  senha; sem ela, o script lê o segredo fcg/eks/admin do Secrets Manager
#                  (precisa de AWS CLI com AWS_PROFILE) ou ADMIN_PASSWORD do .env
#   SEED_TOKEN     JWT pronto (pula o login)
#   GAMES_URL      endpoint de jogos; padrão $BASE_URL/catalog/api/v1/games
#
# Idempotente: jogos com o mesmo título já cadastrado são pulados, então pode rodar de novo.
# Só bash, curl, sed e grep (sem jq), para funcionar também no Git Bash do Windows.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/k8s/common.sh"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

NAMESPACE="${NAMESPACE:-fcg}"
REGION="${AWS_REGION:-us-east-1}"
SEED_EMAIL="${SEED_EMAIL:-admin@fcg.com}"

# ----------------------------------------------------------------------------- jogos
# título|gênero|preço|descrição. Títulos e descrições com mais de 10 caracteres (regra da
# API) e sem aspas duplas nem barra invertida (o JSON é montado com printf).
# Alguns pares existem de propósito para a demo da busca:
#   "witchr" acha The Witcher 3 (título) acima do Gwent (só na descrição);
#   "pokemon" acha os dois Pokémon (acento ignorado);
#   genre=Strategy, maxPrice=50, term=open world...
GAMES=$(cat <<'EOF'
The Witcher 3: Wild Hunt|RPG|99.90|Open world RPG with monster hunting and choices that matter
Gwent: The Card Game|Strategy|0|Free card game set in the world of The Witcher
Pokémon Legends: Arceus|RPG|299.90|Catch them all in the ancient Hisui region
Pokémon Scarlet and Violet|RPG|299.90|Open world Pokémon adventure in the Paldea region
Elden Ring: Nightreign|Action|199.90|Cooperative action roguelike in the Lands Between
Hollow Knight: Silksong|Action|59.90|Metroidvania adventure in a kingdom ruled by silk and song
The Legend of Zelda: Tears of the Kingdom|Action|349.90|Open world adventure in the skies and depths of Hyrule
Red Dead Redemption 2|Action|149.90|Western adventure in the last days of the outlaws
Cyberpunk 2077|RPG|199.90|Open world RPG in the neon streets of Night City
Baldur's Gate 3|RPG|199.90|Party based RPG with turn based combat and deep choices
Civilization VII|Strategy|299.90|Turn based strategy building an empire through the ages
Age of Empires IV|Strategy|99.90|Real time strategy with historical civilizations
StarCraft II: Legacy of the Void|Strategy|0|Real time strategy between Terrans, Zerg and Protoss
EA Sports FC 26|Sports|349.90|Football simulation with real clubs and leagues
NBA 2K26 Standard Edition|Sports|299.90|Basketball simulation with real NBA teams
Gran Turismo 7|Sports|249.90|Racing simulator with hundreds of real cars
Tetris Effect: Connected|Puzzle|99.90|Classic falling blocks puzzle with music and lights
Monument Valley 3|Puzzle|29.90|Optical illusion puzzles through impossible architecture
Stardew Valley|Other|24.90|Farming life simulation in a small countryside town
Minecraft: Java Edition|Other|99.90|Sandbox game to build and explore block worlds
EOF
)

# ------------------------------------------------------------------------- endereço
if [[ -z "${GAMES_URL:-}" ]]; then
  if [[ -z "${BASE_URL:-}" ]]; then
    host="$(kubectl get service kong-public -n "$NAMESPACE" \
      -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
    BASE_URL="${host:+http://$host}"
    BASE_URL="${BASE_URL:-http://localhost:8000}"
  fi
  BASE_URL="${BASE_URL%/}"
  GAMES_URL="$BASE_URL/catalog/api/v1/games"
fi
echo "==> Catálogo: $GAMES_URL"

# ---------------------------------------------------------------------------- login
token="${SEED_TOKEN:-}"
if [[ -z "$token" ]]; then
  password="${SEED_PASSWORD:-}"
  if [[ -z "$password" ]]; then
    # EKS: a senha do admin raiz é gerada pelo Secrets Manager (workload-access.yaml).
    password="$(aws secretsmanager get-secret-value --secret-id fcg/eks/admin --region "$REGION" \
      --query SecretString --output text 2>/dev/null |
      sed -n 's/.*"password" *: *"\([^"]*\)".*/\1/p' || true)"
  fi
  if [[ -z "$password" && -f "$ROOT_DIR/.env" ]]; then
    # docker compose: a senha do admin é ADMIN_PASSWORD do .env.
    password="$(sed -n 's/^ADMIN_PASSWORD=//p' "$ROOT_DIR/.env" | tr -d '"\r')"
  fi
  if [[ -z "$password" ]]; then
    echo "!! Sem senha: defina SEED_PASSWORD (ou AWS_PROFILE para ler fcg/eks/admin)." >&2
    exit 1
  fi
  # Corpo pelo stdin: a senha não aparece na lista de processos (ps).
  resp="$(printf '{"email":"%s","password":"%s"}' "$SEED_EMAIL" "$password" |
    curl -sS --max-time 15 -H 'Content-Type: application/json' --data @- \
      "${BASE_URL:-}/users/api/auth/login" || true)"
  token="$(printf '%s' "$resp" | sed -n 's/.*"accessToken" *: *"\([^"]*\)".*/\1/p')"
  if [[ -z "$token" ]]; then
    echo "!! Login de $SEED_EMAIL falhou. O users-api criou o admin? (log: 'Admin raiz criado')" >&2
    exit 1
  fi
fi
auth=(-H "Authorization: Bearer $token")

# ------------------------------------------------------------- títulos já cadastrados
existing=""
page=1
while :; do
  body="$(curl -sS --max-time 15 "${auth[@]}" "$GAMES_URL?page=$page&pageSize=50")"
  titles="$(printf '%s' "$body" | grep -o '"title":"[^"]*"' | sed 's/"title":"\(.*\)"/\1/' || true)"
  [[ -z "$titles" ]] && break
  existing+="$titles"$'\n'
  [[ "$(printf '%s\n' "$titles" | wc -l)" -lt 50 ]] && break
  page=$((page + 1))
done

# --------------------------------------------------------------------------- cadastro
# A API recusa lançamento no passado: um ano à frente (GNU date no Linux, BSD no macOS).
release="$(date -d '+1 year' +%F 2>/dev/null || date -v+1y +%F)"
created=0 skipped=0 failed=0
while IFS='|' read -r title genre price description; do
  [[ -z "$title" ]] && continue
  if printf '%s' "$existing" | grep -Fxq -- "$title"; then
    skipped=$((skipped + 1))
    continue
  fi
  status="$(printf '{"title":"%s","description":"%s","price":%s,"genre":"%s","releaseDate":"%s"}' \
      "$title" "$description" "$price" "$genre" "$release" |
    curl -sS --max-time 15 -o /dev/null -w '%{http_code}' "${auth[@]}" \
      -H 'Content-Type: application/json' --data @- "$GAMES_URL" || echo 000)"
  if [[ "$status" == "201" ]]; then
    created=$((created + 1))
    echo "   + $title"
  else
    failed=$((failed + 1))
    echo "   ! $title -> HTTP $status" >&2
  fi
done <<< "$GAMES"

echo "==> Criados: $created | já existiam: $skipped | falhas: $failed"
echo "    Teste a busca: curl -H \"Authorization: Bearer \$TOKEN\" \"${GAMES_URL}/search?term=witchr\""
[[ "$failed" -eq 0 ]]
