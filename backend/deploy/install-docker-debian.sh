#!/bin/sh
# Fresh-host prerequisite installer using Docker's official Debian apt repository.
# https://docs.docker.com/engine/install/debian/
set -eu

if command -v docker >/dev/null 2>&1 && sudo -n docker compose version >/dev/null 2>&1; then
    printf 'Docker Engine and Compose already available.\n'
    exit 0
fi

. /etc/os-release
case "$ID:$VERSION_CODENAME" in
    debian:bookworm|debian:trixie) ;;
    *) printf 'This installer supports Debian 12/13.\n' >&2; exit 1 ;;
esac

sudo -n apt-get update
sudo -n env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates curl
sudo -n install -m 0755 -d /etc/apt/keyrings
docker_key_tmp=$(mktemp)
trap 'rm -f "$docker_key_tmp"' EXIT
curl -fsSL https://download.docker.com/linux/debian/gpg -o "$docker_key_tmp"
sudo -n install -m 0644 "$docker_key_tmp" /etc/apt/keyrings/docker.asc
{
    printf 'Types: deb\nURIs: https://download.docker.com/linux/debian\n'
    printf 'Suites: %s\nComponents: stable\n' "$VERSION_CODENAME"
    printf 'Architectures: %s\n' "$(dpkg --print-architecture)"
    printf 'Signed-By: /etc/apt/keyrings/docker.asc\n'
} | sudo -n tee /etc/apt/sources.list.d/docker.sources >/dev/null
sudo -n apt-get update
sudo -n env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo -n systemctl enable --now docker
sudo -n docker version --format '{{.Server.Version}}'
sudo -n docker compose version
