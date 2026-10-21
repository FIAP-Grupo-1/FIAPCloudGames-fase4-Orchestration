#!/bin/sh
# Renderiza a config declarativa do Kong e sobe o gateway.
#
# Por que existe: o Kong DB-less le um YAML estatico e NAO faz interpolacao de
# variaveis de ambiente. As credenciais de JWT (`jwt_secrets.secret`) tambem nao
# aceitam referencia de vault (`{vault://env/...}`) - o campo nao e
# "referenceable" no Kong 3.x e a referencia acabaria sendo usada como a propria
# chave HMAC, quebrando toda validacao com "Invalid signature".
#
# Entao, na subida do container, trocamos dois placeholders do kong.yml:
#   __JWT_SECRET_KEY__ -> $JWT_SECRET_KEY   (segredo HMAC compartilhado)
#   __JWT_ISSUER__     -> $JWT_ISSUER       (claim `iss` esperada nos tokens)
#
# Resultado: nenhum segredo versionado no repo. O arquivo renderizado fica
# apenas no filesystem efemero do container (/tmp), com permissao 0600.
#
# Cuidados com o segredo (por que o script e mais chato do que um `sed`):
#   1. o valor NAO vai na linha de comando do awk (`-v secret=...`), porque
#      argv e legivel por qualquer processo do container via `ps`/procfs;
#      passamos por ENVIRON, que so o proprio processo le;
#   2. o valor NAO fica no ambiente do Kong: `unset` antes do exec, para o
#      segredo nao aparecer em /proc/1/environ nem em dump de crash;
#   3. a substituicao e literal byte a byte e o valor sai como escalar YAML
#      entre aspas simples, entao segredo com `&`, `|`, `"`, `\` ou `$` nao
#      corrompe o arquivo nem gera uma chave HMAC silenciosamente errada.
#
# Usado igual nos dois ambientes:
#   Compose: entrypoint: ["/bin/sh", "/kong/declarative/render-and-start.sh"]
#   k8s:     command:    ["/bin/sh", "/kong/declarative/render-and-start.sh"]
set -eu

TEMPLATE="${KONG_DECLARATIVE_TEMPLATE:-/kong/declarative/kong.yml}"
RENDERED="${KONG_DECLARATIVE_RENDERED:-/tmp/kong.rendered.yml}"
JWT_ISSUER="${JWT_ISSUER:-FCG}"

if [ ! -f "$TEMPLATE" ]; then
  echo "!! kong: template declarativo nao encontrado em $TEMPLATE" >&2
  exit 1
fi

if [ -z "${JWT_SECRET_KEY:-}" ]; then
  echo "!! kong: JWT_SECRET_KEY nao definida." >&2
  echo "   Compose: defina no .env (mesma chave usada por users-api e catalog-api)." >&2
  echo "   k8s:     confira a key JwtSettings__SecretKey no Secret fcg-secrets." >&2
  exit 1
fi

export JWT_ISSUER

# O arquivo renderizado carrega o segredo em texto: cria com 0600 ANTES de
# escrever, para nao existir nem uma janela em que ele fique legivel por outros.
# O umask volta ao valor original em seguida - o Kong ainda vai criar o proprio
# prefixo (sockets, logs, pids) e nao queremos mexer nessas permissoes.
OLD_UMASK="$(umask)"
umask 077
: > "$RENDERED"
umask "$OLD_UMASK"

# Substituicao LITERAL. Nao usamos `sed s|...|...|` porque o sed interpreta '&'
# e o proprio delimitador dentro do valor. O awk abaixo trabalha com
# index/substr, ou seja, byte a byte, sem interpretar nada, e devolve o valor
# como escalar YAML single-quoted (aspa simples interna duplicada, conforme a
# spec do YAML) - e por isso que o kong.yml traz os placeholders SEM aspas.
awk '
  function yaml_squote(v,   out, i, n, c, sq) {
    sq = sprintf("%c", 39)              # aspa simples (fora de literal, para
    out = sq                            # nao brigar com as aspas do shell)
    n = length(v)
    for (i = 1; i <= n; i++) {
      c = substr(v, i, 1)
      out = out c
      # Aspa simples dentro de escalar single-quoted se escapa duplicando.
      if (c == sq) out = out sq
    }
    return out sq
  }
  function subst_all(line, ph, value,    i, n) {
    n = length(ph)
    while ((i = index(line, ph)) > 0)
      line = substr(line, 1, i - 1) value substr(line, i + n)
    return line
  }
  BEGIN {
    # Via ENVIRON, nao via -v: mantem o segredo fora da linha de comando.
    secret = yaml_squote(ENVIRON["JWT_SECRET_KEY"])
    issuer = yaml_squote(ENVIRON["JWT_ISSUER"])
  }
  {
    $0 = subst_all($0, "__JWT_SECRET_KEY__", secret)
    $0 = subst_all($0, "__JWT_ISSUER__", issuer)
    print
  }
' "$TEMPLATE" > "$RENDERED"

# Cinto de seguranca: se algum placeholder sobrou, aborta em vez de subir um
# gateway que rejeitaria (ou aceitaria) tokens pelo motivo errado.
if grep -q '__JWT_SECRET_KEY__\|__JWT_ISSUER__' "$RENDERED"; then
  echo "!! kong: placeholders nao substituidos em $RENDERED" >&2
  exit 1
fi

echo "==> kong: config declarativa renderizada em $RENDERED (issuer esperado: '$JWT_ISSUER')"

# O Kong le o segredo do ARQUIVO renderizado; nao precisa dele no ambiente.
# Remover aqui evita que ele fique exposto em /proc/<pid>/environ do processo
# principal do container (visivel para quem consiga um `kubectl exec`).
unset JWT_SECRET_KEY

export KONG_DECLARATIVE_CONFIG="$RENDERED"
exec /docker-entrypoint.sh "$@"