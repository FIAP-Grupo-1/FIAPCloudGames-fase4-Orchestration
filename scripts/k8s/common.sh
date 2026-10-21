#!/usr/bin/env bash
# Ajustes de ambiente para Windows (Git Bash) e Linux.
set -euo pipefail

# Git Bash no Windows as vezes define HOME como path invalido (ex.: C:Usersander).
if [[ "$(uname -s)" == MINGW* || "$(uname -s)" == MSYS* ]]; then
  export HOME="/c/Users/$(whoami)"
  export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
fi
