#!/usr/bin/env bash

set -euo pipefail

# =============================================================================
# InstallDeepSeekR1.sh
#
# Pulls a DeepSeek-R1 model into the existing Ollama container so it appears in
# Open WebUI.
#
# Usage:
#   ./InstallDeepSeekR1.sh
#   ./InstallDeepSeekR1.sh <extra-model-tag>
#
# Defaults:
#   - Container name: ollama
#   - Always installs: deepseek-r1:8b and deepseek-r1:14b
#   - Optional: one additional model tag argument
# =============================================================================

OLLAMA_CONTAINER_NAME="${OLLAMA_CONTAINER_NAME:-ollama}"
BASE_MODELS=("deepseek-r1:8b" "deepseek-r1:14b")
EXTRA_MODEL="${1:-}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

DOCKER_USE_SUDO="false"
docker_exec() {
  if [[ "${DOCKER_USE_SUDO}" == "true" ]]; then
    sudo docker "$@"
  else
    docker "$@"
  fi
}

container_exists() {
  docker_exec ps -aq --filter "name=^/$1$" 2>/dev/null | grep -q .
}

container_running() {
  docker_exec ps -q --filter "name=^/$1$" 2>/dev/null | grep -q .
}

if [[ "$#" -gt 1 ]]; then
  log "Error: too many arguments."
  log "Usage: $0 [extra-model-tag]"
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  log "Error: Docker is not installed."
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  if sudo docker info >/dev/null 2>&1; then
    DOCKER_USE_SUDO="true"
    log "Using 'sudo docker' for this session (user not yet in docker group)."
  else
    log "Error: cannot connect to Docker daemon. Is Docker running?"
    exit 1
  fi
fi

if ! container_exists "${OLLAMA_CONTAINER_NAME}"; then
  log "Error: container '${OLLAMA_CONTAINER_NAME}' not found."
  log "Run your Ollama setup script first: bash miniscripts/containers/RunOllamaContainer.sh"
  exit 1
fi

if ! container_running "${OLLAMA_CONTAINER_NAME}"; then
  log "Starting '${OLLAMA_CONTAINER_NAME}' container..."
  docker_exec start "${OLLAMA_CONTAINER_NAME}" >/dev/null
fi

log "Checking Ollama CLI availability inside container..."
if ! docker_exec exec "${OLLAMA_CONTAINER_NAME}" ollama --version >/dev/null 2>&1; then
  log "Error: Ollama CLI is not available inside '${OLLAMA_CONTAINER_NAME}'."
  exit 1
fi

MODELS_TO_INSTALL=("${BASE_MODELS[@]}")
if [[ -n "${EXTRA_MODEL}" ]]; then
  MODELS_TO_INSTALL+=("${EXTRA_MODEL}")
fi

for MODEL_NAME in "${MODELS_TO_INSTALL[@]}"; do
  if docker_exec exec "${OLLAMA_CONTAINER_NAME}" ollama list | awk 'NR>1 {print $1}' | grep -qx "${MODEL_NAME}"; then
    log "Model already installed: ${MODEL_NAME}"
    continue
  fi

  log "Pulling model: ${MODEL_NAME}"
  log "This can take a while depending on model size and network speed..."
  docker_exec exec "${OLLAMA_CONTAINER_NAME}" ollama pull "${MODEL_NAME}"

  if docker_exec exec "${OLLAMA_CONTAINER_NAME}" ollama list | awk 'NR>1 {print $1}' | grep -qx "${MODEL_NAME}"; then
    log "Success: ${MODEL_NAME} is installed in Ollama."
  else
    log "Error: model pull did not verify successfully for ${MODEL_NAME}."
    exit 1
  fi
done

log "Open WebUI should show the model shortly at: http://localhost:3000"
log "If it does not appear immediately, refresh the page or restart Open WebUI:"
log "  docker restart open-webui"
