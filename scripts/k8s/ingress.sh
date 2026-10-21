#!/usr/bin/env bash
# Habilita o addon de Ingress do Minikube e aplica o manifesto k8s/30-ingress.yaml.
# O "minikube tunnel" e a edicao do arquivo de hosts continuam manuais (ver saida final).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$ROOT_DIR"

echo "==> Habilitando addon de ingress no Minikube"
minikube addons enable ingress

echo "==> Esperando o controller do ingress subir"
kubectl wait --for=condition=Ready pods -n ingress-nginx -l app.kubernetes.io/component=controller --timeout=180s

echo "==> Aplicando manifesto de ingress"
kubectl apply -f k8s/30-ingress.yaml

kubectl get ingress -n fcg

cat <<'EOF'

==> Ingress pronto. Passos restantes (manuais, nao automatizaveis):

1. Em outro terminal (no Windows: PowerShell como administrador), execute e deixe rodando:
     minikube tunnel

2. Adicione ao arquivo de hosts:
     Linux/Mac: /etc/hosts
     Windows:   C:\Windows\System32\drivers\etc\hosts (editar como administrador)

     127.0.0.1 gateway.fcg.local
     127.0.0.1 users.fcg.local
     127.0.0.1 catalog.fcg.local
     127.0.0.1 payments.fcg.local
     127.0.0.1 rabbitmq.fcg.local
EOF
