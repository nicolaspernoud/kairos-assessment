#!/bin/bash
set -Eeuxo pipefail
WD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd ${WD}

COMPANY_NAME="acme"
CONTAINER_IMAGE=${COMPANY_NAME}-os-v2-base
IMAGE_NAME=${COMPANY_NAME}-os-v2
KAIROS_VERSION=3.1.1
BRIDGE_IP=$(ip -f inet addr show virbr0 | sed -En -e 's/.*inet ([0-9.]+).*/\1/p')

# Step 1: create the updated Dockerfile
cat <<EOF >./Dockerfile.update
FROM quay.io/kairos/ubuntu:24.04-core-amd64-generic-v${KAIROS_VERSION}
# Customizations
RUN echo "test v2" > /etc/test.txt
EOF

# Step 2: build the updated Container
sudo rm -rf build/upgrade-image/
docker build . -t ${CONTAINER_IMAGE} -f Dockerfile.update

docker run \
    -ti \
    --rm \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v $PWD/keys:/keys \
    -v $PWD/build:/work \
    quay.io/kairos/osbuilder-tools:v0.300.3 \
    build-uki $CONTAINER_IMAGE \
    --boot-branding "${COMPANY_NAME^} OS" \
    -t container \
    -d /work/upgrade-image \
    -k /keys

docker load -i build/upgrade-image/*.tar
docker tag kairos_uki_v${KAIROS_VERSION}.tar:latest localhost:5000/${IMAGE_NAME}

# Step 3: start a local registry
docker stop registry
docker rm registry
docker run -d -p 5000:5000 --name registry registry:2.8.3
sleep 5

# Step 4: push the image to the registry
docker push localhost:5000/${IMAGE_NAME}

# Step 5: ssh to kairos and start update
ssh-keygen -f "/home/$USER/.ssh/known_hosts" -R "[${BRIDGE_IP}]:2222"
ssh -o "IdentitiesOnly=yes" -i ./id_rsa kairos@${BRIDGE_IP} -p 2222 "sudo kairos-agent upgrade --source oci:${BRIDGE_IP}:5000/${IMAGE_NAME}:latest && sudo reboot"
