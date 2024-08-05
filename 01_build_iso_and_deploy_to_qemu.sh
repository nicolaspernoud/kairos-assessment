#!/bin/bash
set -Eeuxo pipefail
WD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd ${WD}

KAIROS_VERSION=3.1.1
COMPANY_NAME="acme"
ISO_NAME="${COMPANY_NAME}-os"
KAIROS_USER=kairos

# Step 0: reset
sudo rm -f *.fd *.img
# sudo rm -rf build/ files-iso/ keys/ enki/ id_rsa* Dockerfile*

# Step 1: create the Dockerfile
if [ ! -e "id_rsa" ]; then
  ssh-keygen -t rsa -b 4096 -f ./id_rsa
fi

cat <<EOF >./Dockerfile
FROM quay.io/kairos/ubuntu:24.04-core-amd64-generic-v${KAIROS_VERSION}
# Customizations
RUN echo "test" > /etc/test.txt
EOF

# Step 2: create the cloud init file
mkdir -p ./files-iso
cat <<EOF >./files-iso/cloud_init.yaml
#cloud-config

install:
  reboot: true
  poweroff: false
  auto: true # Required, for automated installations
  bind_mounts:
    - /var/lib/${COMPANY_NAME}

users:
  - name: ${KAIROS_USER}
    lock_passwd: true
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - $(cat id_rsa.pub)

write_files:
  - path: /var/log/${COMPANY_NAME}.log
    content: |
      # ${COMPANY_NAME^} cloud init done
EOF

# Step 3: generate the keys
if [ ! -e "./keys" ]; then
  mkdir -p ./keys
  docker run -v $PWD/keys:/work/keys -ti --rm quay.io/kairos/osbuilder-tools:latest genkey "${COMPANY_NAME^}" --skip-microsoft-certs-I-KNOW-WHAT-IM-DOING --expiration-in-days 365 -o /work/keys
fi

# Step 4: Build installable medium with keys
if [ ! -e "./build/${ISO_NAME}.iso" ]; then
  IMAGE=${ISO_NAME}:latest
  docker build --tag $IMAGE .
  docker run \
    -ti \
    --rm \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v $PWD/build:/result \
    -v $PWD/keys/:/keys \
    -v $PWD/files-iso:/files-iso \
    quay.io/kairos/osbuilder-tools:v0.300.3 \
    build-uki $IMAGE \
    --name "${ISO_NAME}" \
    --overlay-iso /files-iso \
    --boot-branding "${COMPANY_NAME^} OS" \
    -t iso \
    -d /result/ \
    -k /keys
  sudo chown -Rf $USER:$USER ./build
  sudo chmod -Rf 777 ./build
fi

# Step 5: QEMU Test
MACHINE_NAME="test"
QEMU_IMG="${MACHINE_NAME}.img"
SSH_PORT="2222"
OVMF_CODE="/usr/share/OVMF/OVMF_CODE_4M.ms.fd"
OVMF_VARS_ORIG="/usr/share/OVMF/OVMF_VARS_4M.ms.fd"
OVMF_VARS="$(basename "${OVMF_VARS_ORIG}")"

if [ ! -e "${QEMU_IMG}" ]; then
  qemu-img create -f qcow2 "${QEMU_IMG}" 40G
fi

if [ ! -e "${OVMF_VARS}" ]; then
  cp "${OVMF_VARS_ORIG}" "${OVMF_VARS}"
fi

# TPM Emulator
mkdir -p /tmp/mytpm1
swtpm socket --tpmstate dir=/tmp/mytpm1 \
  --ctrl type=unixio,path=/tmp/mytpm1/swtpm-sock \
  --tpm2 \
  --log level=20 &
TPM_PID=$!

# Start VM (needs a lot of RAM to allow update image check)
qemu-system-x86_64 \
  -enable-kvm \
  -cpu host -smp cores=4,threads=1 -m 12288 \
  -object rng-random,filename=/dev/urandom,id=rng0 \
  -device virtio-rng-pci,rng=rng0 \
  -name "${MACHINE_NAME}" \
  -drive file="${QEMU_IMG}",format=qcow2 \
  -net nic,model=virtio -net user,hostfwd=tcp::${SSH_PORT}-:22 \
  -vga virtio \
  -machine q35,smm=on \
  -global driver=cfi.pflash01,property=secure,value=on \
  -drive if=pflash,format=raw,unit=0,file="${OVMF_CODE}",readonly=on \
  -drive if=pflash,format=raw,unit=1,file="${OVMF_VARS}" \
  -chardev socket,id=chrtpm,path=/tmp/mytpm1/swtpm-sock \
  -tpmdev emulator,id=tpm0,chardev=chrtpm \
  -device tpm-tis,tpmdev=tpm0 \
  -cdrom ./build/${ISO_NAME}.iso -boot menu=on,splash-time=10000 -monitor stdio

kill $TPM_PID
