# Automacao do deploy no Kubernetes (Minikube) da FCG Fase 3.
# Uso: `make k8s-up` sobe tudo. `make help` lista os comandos.
#
# Requisitos: docker, minikube, kubectl, bash (Linux/Mac nativo; Windows via Git Bash).

ifeq ($(OS),Windows_NT)
    BASH := "C:/Program Files/Git/bin/bash.exe"
else
    BASH := bash
endif

SHELL := $(BASH)
NAMESPACE ?= fcg

.PHONY: help k8s-start k8s-build k8s-deploy k8s-up k8s-status k8s-ingress k8s-down kong-config k8s-secrets

help:
	@echo "Comandos disponiveis:"
	@echo "  make k8s-up       - start do Minikube + build/load das imagens + deploy (fluxo completo)"
	@echo "  make k8s-start    - so inicia o cluster Minikube"
	@echo "  make k8s-build    - so builda e carrega as 4 imagens no Minikube"
	@echo "  make k8s-deploy   - so aplica os manifestos k8s/ (regera a config do Kong e o ConfigMap do init do DynamoDB local, rolando o que mudou) e espera os pods"
	@echo "  make k8s-status   - mostra pods, deployments, services, configmaps e secrets do namespace $(NAMESPACE)"
	@echo "  make k8s-ingress  - habilita o Ingress do Minikube e aplica o manifesto de ingress"
	@echo "  make k8s-down     - remove o namespace $(NAMESPACE) (derruba tudo)"
	@echo "  make kong-config  - regera k8s/03-kong-config.yaml a partir de kong/ (rode apos editar kong/kong.yml)"
	@echo "  make k8s-secrets  - reaplica os segredos reais do .env no cluster (New Relic e AWS)"

k8s-start:
	@echo "==> Iniciando o cluster Minikube"
	@echo "    (ingress fica desabilitado aqui; use 'make k8s-ingress' depois, se precisar)"
	-minikube addons disable ingress 2>/dev/null || true
	minikube start --wait=all

k8s-build:
	@$(BASH) scripts/k8s/build-images.sh

kong-config:
	@$(BASH) scripts/kong/sync-configmap.sh

k8s-secrets:
	@$(BASH) scripts/k8s/secrets.sh

k8s-deploy:
	@$(BASH) scripts/k8s/deploy.sh
	@$(BASH) scripts/k8s/wait-ready.sh

k8s-up: k8s-start k8s-build k8s-deploy
	@echo "==> Stack no ar. Use 'make k8s-status' para ver os pods."

k8s-status:
	kubectl get pods,deployments,services,configmaps,secrets -n $(NAMESPACE)

k8s-ingress:
	@$(BASH) scripts/k8s/ingress.sh

k8s-down:
	@echo "==> Removendo o namespace $(NAMESPACE)"
	-kubectl delete namespace $(NAMESPACE)
