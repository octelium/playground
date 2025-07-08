#!/usr/bin/env bash
# Copyright 2025 Octelium Labs, LLC. All rights reserved. Apache 2.0 license.

DOMAIN="localhost"
VERSION="latest"
DEBIAN_FRONTEND=noninteractive
K8S_VERSION=1.32
PG_PASSWORD=$(openssl rand -base64 12)
REDIS_PASSWORD=$(openssl rand -base64 12)


export OCTELIUM_INSECURE_TLS=true
export OCTELIUM_DOMAIN="localhost"
export KUBECONFIG="/etc/rancher/k3s/k3s.yaml"

echo "export OCTELIUM_INSECURE_TLS=\"$OCTELIUM_INSECURE_TLS\"" >> ~/.bashrc
echo "export OCTELIUM_DOMAIN=\"$OCTELIUM_DOMAIN\"" >> ~/.bashrc
echo "export KUBECONFIG=\"$KUBECONFIG\"" >> ~/.bashrc

if [ -f ~/.zshrc ]; then
  echo "export OCTELIUM_INSECURE_TLS=\"$OCTELIUM_INSECURE_TLS\"" >> ~/.zshrc
  echo "export OCTELIUM_DOMAIN=\"$OCTELIUM_DOMAIN\"" >> ~/.zshrc
  echo "export KUBECONFIG=\"$KUBECONFIG\"" >> ~/.zshrc
fi


echo insecure >> ~/.curlrc

sudo mount --make-rshared /
sudo mkdir -p /usr/local/bin
sudo apt-get update
sudo apt-get install -y iputils-ping postgresql

if [[ ":$PATH:" != *":/usr/local/bin:"* ]]; then
  export PATH="/usr/local/bin:$PATH"
fi


sudo rm -rf /mnt/octelium/db
sudo mkdir -p /mnt/octelium/db
sudo chmod -R 777 /mnt/octelium/db


curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo cp kubectl /usr/local/bin
sudo chmod 755 /usr/local/bin/kubectl

curl -fsSL https://octelium.com/install.sh | bash


export INSTALL_K3S_SKIP_START=true
export INSTALL_K3S_SKIP_ENABLE=true
export INSTALL_K3S_EXEC="--disable traefik"
curl -sfL https://get.k3s.io | sh -

curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod 700 get_helm.sh
sudo ./get_helm.sh

sudo k3s server --disable traefik --docker --write-kubeconfig-mode 644 &>/dev/null &

echo "Installing k3s"

sleep 30

kubectl wait --for=condition=Ready nodes --all --timeout=600s

kubectl taint nodes --all node-role.kubernetes.io/control-plane-

kubectl label nodes --all octelium.com/node=
kubectl label nodes --all octelium.com/node-mode-controlplane=
kubectl label nodes --all octelium.com/node-mode-dataplane=


kubectl wait --for=condition=Ready nodes --all --timeout=600s

DEVICE=$(ip route show default | ip route show default | awk '/default/ {print $5}')
DEFAULT_LINK_ADDR=$(ip addr show "$DEVICE" | grep "inet " | awk '{print $2}' | cut -d'/' -f1)
EXTERNAL_IP=${DEFAULT_LINK_ADDR}

NODE_NAME=$(kubectl get nodes --no-headers -o jsonpath='{.items[0].metadata.name}')

kubectl annotate node ${NODE_NAME} octelium.com/public-ip=${EXTERNAL_IP}

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: octelium-db-pvc
spec:
  resources:
    requests:
      storage: 5Gi
  accessModes:
    - ReadWriteOnce
EOF

kubectl create secret generic octelium-pg --from-literal=postgres-password=${PG_PASSWORD} --from-literal=password=${PG_PASSWORD}
kubectl create secret generic octelium-redis --from-literal=password=${REDIS_PASSWORD}

helm install --namespace kube-system octelium-multus oci://registry-1.docker.io/bitnamicharts/multus-cni --version 2.2.7 \
    --set hostCNIBinDir=/var/lib/rancher/k3s/data/cni/ --set hostCNINetDir=/var/lib/rancher/k3s/agent/etc/cni/net.d

helm install octelium-redis oci://registry-1.docker.io/bitnamicharts/redis \
	--set auth.existingSecret=octelium-redis \
	--set auth.existingSecretPasswordKey=password \
	--set architecture=standalone \
	--set master.persistence.enabled=false \
	--set standalone.persistence.enabled=false \
  --set networkPolicy.enabled=false --version 20.8.0

helm install --wait --timeout 30m0s octelium-pg oci://registry-1.docker.io/bitnamicharts/postgresql \
	--set primary.persistence.existingClaim=octelium-db-pvc \
	--set global.postgresql.auth.existingSecret=octelium-pg \
	--set global.postgresql.auth.database=octelium \
	--set global.postgresql.auth.username=octelium \
  --set primary.networkPolicy.enabled=false --version 16.4.14


export OCTELIUM_REGION_EXTERNAL_IP=${EXTERNAL_IP}
export OCTELIUM_AUTH_TOKEN_SAVE_PATH="/tmp/octelium-auth-token"
export OCTELIUM_SKIP_MESSAGES="true"
octops init ${DOMAIN} --version ${VERSION} --bootstrap - <<EOF
spec:
  primaryStorage:
    postgresql:
      username: octelium
      password: ${PG_PASSWORD}
      host: octelium-pg-postgresql.default.svc
      database: octelium
      port: 5432
  secondaryStorage:
    redis:
      password: ${REDIS_PASSWORD}
      host: octelium-redis-master.default.svc
      port: 6379
EOF

kubectl wait --for=condition=available deployment/svc-default-octelium-api --namespace octelium --timeout=600s
kubectl wait --for=condition=available deployment/svc-auth-octelium-api --namespace octelium --timeout=600s
kubectl wait --for=condition=available deployment/octelium-ingress-dataplane --namespace octelium --timeout=600s
kubectl wait --for=condition=available deployment/octelium-ingress --namespace octelium --timeout=600s


AUTH_TOKEN=$(cat $OCTELIUM_AUTH_TOKEN_SAVE_PATH)

sleep 3

octelium login --domain localhost --auth-token $AUTH_TOKEN

octeliumctl create secret pg --value ${PG_PASSWORD}

source ~/.bashrc
echo -e "\e[1mThe Cluster has been successfully installed. Open a new tab to start using octelium and octeliumctl commands.\e[0m"