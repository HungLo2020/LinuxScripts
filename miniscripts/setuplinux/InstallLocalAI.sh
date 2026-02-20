#!/usr/bin/env bash

set -euo pipefail

TARGET_USER="${SUDO_USER:-$(id -un)}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"

if [[ -z "$TARGET_HOME" || ! -d "$TARGET_HOME" ]]; then
  echo "Error: Could not determine home directory for user '$TARGET_USER'."
  exit 1
fi

COMPOSE_DIR="$TARGET_HOME/.local/share/docker/ollama"
COMPOSE_FILE="$COMPOSE_DIR/compose.yml"

echo "================================================================"
echo " Removing Local AI stack (Ollama + AUTOMATIC1111 + Open WebUI)"
echo "================================================================"

# ---------------------------------------------------------------
# Stop and remove containers via compose (if compose file exists)
# ---------------------------------------------------------------
if [[ -f "$COMPOSE_FILE" ]]; then
  echo "Stopping and removing containers..."
  sudo docker compose -f "$COMPOSE_FILE" down --volumes --remove-orphans 2>/dev/null || true
else
  echo "No compose file found at $COMPOSE_FILE — stopping containers by name..."
fi

# Belt-and-suspenders: remove any lingering named containers individually
for container in ollama automatic1111 open-webui; do
  if [[ -n "$(sudo docker ps -aq --filter "name=^${container}$" 2>/dev/null)" ]]; then
    echo "  Removing container: $container"
    sudo docker rm -f "$container" 2>/dev/null || true
  fi
done

# ---------------------------------------------------------------
# Remove Docker named volumes
# ---------------------------------------------------------------
echo "Removing Docker volumes..."
for volume in ollama open-webui sd-outputs; do
  if [[ -n "$(sudo docker volume ls -q --filter "name=^${volume}$" 2>/dev/null)" ]]; then
    echo "  Removing volume: $volume"
    sudo docker volume rm "$volume" 2>/dev/null || true
  fi
done

# ---------------------------------------------------------------
# Remove Docker images
# ---------------------------------------------------------------
echo "Removing Docker images..."
for image in \
    "ollama/ollama:latest" \
    "ghcr.io/open-webui/open-webui:main" \
    "ghcr.io/jim60105/stable-diffusion-webui:latest"; do
  if sudo docker image inspect "$image" >/dev/null 2>&1; then
    echo "  Removing image: $image"
    sudo docker rmi "$image" 2>/dev/null || true
  fi
done

# ---------------------------------------------------------------
# Delete the compose directory (models, config, yaml, compose file)
# ---------------------------------------------------------------
if [[ -d "$COMPOSE_DIR" ]]; then
  echo "Deleting $COMPOSE_DIR (models and config)..."
  sudo rm -rf "$COMPOSE_DIR"
  echo "  Deleted."
else
  echo "Directory $COMPOSE_DIR does not exist — nothing to delete."
fi

echo ""
echo "================================================================"
echo " Done. Everything has been removed."
echo "  - Containers: stopped and deleted"
echo "  - Docker volumes: deleted (all model data gone)"
echo "  - Docker images: removed"
echo "  - Model files and config: deleted ($COMPOSE_DIR)"
echo "================================================================"

