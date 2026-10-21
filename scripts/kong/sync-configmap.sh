#!/usr/bin/env bash
# Gera k8s/03-kong-config.yaml a partir dos arquivos de kong/.
#
# Motivo: o Compose monta kong/ direto como volume, mas no Kubernetes o mesmo
# conteudo precisa virar um ConfigMap. Em vez de manter duas copias (e deixar
# uma desatualizar), o ConfigMap e GERADO do mesmo fonte -- kong/kong.yml segue
# sendo a unica fonte de verdade das rotas.
#
# Rode `make kong-config` depois de editar qualquer arquivo em kong/.
# O deploy.sh tambem chama este script, entao `make k8s-up` nunca aplica
# um ConfigMap defasado.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$ROOT_DIR"

OUT="k8s/03-kong-config.yaml"
SOURCES=("kong/kong.yml" "kong/render-and-start.sh")

for f in "${SOURCES[@]}"; do
  [ -f "$f" ] || { echo "!! arquivo fonte ausente: $f" >&2; exit 1; }
done

# Hash do conteudo das fontes. Vai numa annotation do ConfigMap e o deploy.sh o
# copia para o pod template do Deployment kong -- e isso que faz os pods
# rolarem quando (e somente quando) a config muda. Sem isso, `kubectl apply`
# troca o ConfigMap e o Kong segue rodando a config antiga: ele le o YAML
# declarativo UMA VEZ, no startup.
CONFIG_HASH="$(cat "${SOURCES[@]}" | sha256sum | cut -c1-12)"

# Indenta o conteudo em 4 espacos para caber no bloco literal (|) do ConfigMap.
# Linhas vazias ficam realmente vazias -- 4 espacos soltos viram trailing
# whitespace e alguns parsers de YAML reclamam.
emit_entry() {
  local path="$1" key="$2"
  printf '  %s: |\n' "$key"
  awk '{ if (length($0) == 0) print ""; else print "    " $0 }' "$path"
}

{
  cat <<'HEADER'
# ============================================================================
# ARQUIVO GERADO -- NAO EDITE A MAO.
#
# Fonte:     kong/kong.yml e kong/render-and-start.sh
# Regenerar: make kong-config   (scripts/kong/sync-configmap.sh)
#
# Config declarativa do Kong (DB-less) montada em /kong/declarative no pod.
# Nao contem segredo: o JWT_SECRET_KEY entra em runtime, via Secret fcg-secrets.
# ============================================================================
apiVersion: v1
kind: ConfigMap
metadata:
  name: kong-declarative
  namespace: fcg
HEADER
  cat <<ANNOTATIONS
  annotations:
    # Hash das fontes; o deploy.sh o replica no pod template do Deployment kong
    # para forcar o rollout quando a config declarativa muda.
    fcg.dev/kong-config-hash: "$CONFIG_HASH"
ANNOTATIONS
  echo "data:"
  emit_entry "kong/kong.yml" "kong.yml"
  emit_entry "kong/render-and-start.sh" "render-and-start.sh"
} > "$OUT"

echo "==> $OUT gerado a partir de: ${SOURCES[*]} (hash ${CONFIG_HASH})"

# Validacao: o YAML tem de continuar parseavel e o conteudo embutido tem de
# bater byte a byte com os arquivos fonte.
if command -v python3 >/dev/null 2>&1; then
  python3 - "$OUT" "${SOURCES[@]}" <<'PYCHECK'
import pathlib, sys, yaml

out, sources = sys.argv[1], sys.argv[2:]
data = yaml.safe_load(pathlib.Path(out).read_text())["data"]

for src in sources:
    key = pathlib.Path(src).name
    original = pathlib.Path(src).read_text()
    # O bloco literal (|) do YAML normaliza o fim do arquivo em uma unica \n.
    if original.rstrip("\n") != data[key].rstrip("\n"):
        sys.exit(f"!! conteudo de {key} no ConfigMap difere de {src}")

print("==> Round-trip OK: conteudo embutido identico aos arquivos fonte.")
PYCHECK
fi

if command -v kubectl >/dev/null 2>&1; then
  kubectl apply --dry-run=client -f "$OUT" >/dev/null
  echo "==> ConfigMap valido (kubectl apply --dry-run=client)."
fi
