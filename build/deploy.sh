#!/bin/bash
# Installs the packages from dist/ on the box:  build/deploy.sh root@HC4
# Local changes to the files in /etc are kept.
set -euo pipefail
HOST=${1:?usage: build/deploy.sh user@host}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
ssh "$HOST" 'rm -rf /tmp/hmp-deploy && mkdir /tmp/hmp-deploy'
scp -q "$ROOT"/dist/*.deb "$HOST:/tmp/hmp-deploy/"
ssh "$HOST" 'DEBIAN_FRONTEND=noninteractive apt-get install -y --reinstall \
    -o Dpkg::Options::=--force-confold /tmp/hmp-deploy/*.deb && rm -rf /tmp/hmp-deploy'
