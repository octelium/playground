#!/usr/bin/env bash
# Copyright 2026 Octelium Labs, LLC. All rights reserved. Apache 2.0 license.

# Shell snippets and envsubst intentionally defer variable expansion.
# shellcheck disable=SC2016
set -Eeuo pipefail
shopt -s inherit_errexit 2>/dev/null || true
umask 077

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
STATE_DIR=${OCTELIUM_STATE_DIR:-$SCRIPT_DIR/.state}
DOMAIN=localhost
VERSION=${OCTELIUM_VERSION:-latest}
K3S_VERSION=${OCTELIUM_K3S_VERSION:-}
DB_DIR=${OCTELIUM_DB_DIR:-/mnt/octelium/playground-db}
DB_SIZE=${OCTELIUM_DB_SIZE:-5Gi}
TIMEOUT=${OCTELIUM_WAIT_TIMEOUT:-900}
PRINT_MANIFESTS=false
TMP_DIR=

export NS=default
export PG_APP=octelium-postgresql PG_SECRET_NAME=octelium-pg
export PG_PV_NAME=octelium-db-pv PG_PVC_NAME=octelium-db-pvc PG_STORAGE_CLASS=octelium-local
export VALKEY_APP=octelium-valkey VALKEY_SECRET_NAME=octelium-valkey
export MULTUS_APP=octelium-multus PRIORITY_CLASS=octelium-datastore
export PG_IMAGE=${OCTELIUM_PG_IMAGE:-postgres:17-alpine}
export VALKEY_IMAGE=${OCTELIUM_VALKEY_IMAGE:-valkey/valkey:9.1.1-alpine}
export MULTUS_IMAGE=${OCTELIUM_MULTUS_IMAGE:-ghcr.io/k8snetworkplumbingwg/multus-cni:v4.3.0}
export PG_RUN_UID=70 PG_RUN_GID=70 VALKEY_RUN_UID=999 VALKEY_RUN_GID=1000
export PG_CPU_REQUEST=10m PG_MEMORY_REQUEST=64Mi
export VALKEY_CPU_REQUEST=5m VALKEY_MEMORY_REQUEST=32Mi
export MULTUS_CPU_REQUEST=5m MULTUS_MEMORY_REQUEST=16Mi
export CNI_CONF_DIR=/var/lib/rancher/k3s/agent/etc/cni/net.d
export CNI_BIN_DIR=/var/lib/rancher/k3s/data/cni
# Match the upstream Multus delegate lookup path and gwagent host mount.
export MULTUS_CONF_DIR=/etc/cni/multus/net.d
export DB_DIR DB_SIZE
export DEBIAN_FRONTEND=noninteractive
export OCTELIUM_DOMAIN=$DOMAIN OCTELIUM_INSECURE_TLS=true OCTELIUM_SKIP_MESSAGES=true

log() { printf '[playground] %s\n' "$*"; }
die() { printf '[playground] ERROR: %s\n' "$*" >&2; exit 1; }
as_root() { if (( EUID == 0 )); then "$@"; else sudo "$@"; fi; }
kc() { as_root k3s kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml "$@"; }
download() { curl -q -fsSL --retry 3 --connect-timeout 10 --max-time 180 "$@"; }

cleanup() { [[ -z "$TMP_DIR" ]] || rm -rf -- "$TMP_DIR"; }
on_error() {
  local rc=$?
  trap - ERR
  printf '[playground] Installation failed near line %s (exit %s).\n' "${BASH_LINENO[0]}" "$rc" >&2
  if command -v k3s >/dev/null; then
    kc --request-timeout=10s get pods -A -o wide >&2 || true
    kc --request-timeout=10s get events -A --field-selector=type=Warning --sort-by=.lastTimestamp >&2 || true
  fi
  [[ ! -f "$STATE_DIR/k3s.log" ]] || tail -n 40 "$STATE_DIR/k3s.log" >&2
  printf '[playground] Fix the reported error and rerun bash install.sh to resume.\n' >&2
  exit "$rc"
}
trap cleanup EXIT
trap on_error ERR

usage() {
  cat <<'EOF'
Usage: bash install.sh [--version VERSION] [--k3s-version VERSION] [--print-manifests]

Install a single-node localhost Octelium playground in a privileged Codespace.
Run as the normal Codespace user; privileged commands use sudo.
Reruns preserve the database and credentials and restart K3s when necessary.

Options:
  --version VERSION      Octelium release (default: latest; first install only)
  --k3s-version VERSION   K3s release (default: stable; first install only)
  --print-manifests      Render dependency manifests with dummy credentials and exit
  -h, --help             Show this help

Overrides: OCTELIUM_STATE_DIR, OCTELIUM_DB_DIR, OCTELIUM_DB_SIZE,
OCTELIUM_VERSION, OCTELIUM_K3S_VERSION, OCTELIUM_WAIT_TIMEOUT (seconds),
OCTELIUM_GATEWAY_IP (local IPv4), OCTELIUM_PG_IMAGE, OCTELIUM_VALKEY_IMAGE,
OCTELIUM_MULTUS_IMAGE, OCTELIUM_SKIP_CLI_INSTALL=true (use existing CLIs).
Image overrides must retain the default images' UID/GID and data layout.
EOF
}

parse_args() {
  while (( $# )); do
    case "$1" in
      --version|--k3s-version)
        [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || die "$1 requires a value"
        if [[ "$1" == --version ]]; then VERSION=$2; else K3S_VERSION=$2; fi
        shift 2 ;;
      --print-manifests) PRINT_MANIFESTS=true; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unknown option: $1 (see --help)" ;;
    esac
  done
  [[ "$VERSION" =~ ^[A-Za-z0-9._+-]+$ ]] || die 'Invalid Octelium version'
  [[ -z "$K3S_VERSION" || "$K3S_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+\+k3s[0-9]+$ ]] || die 'Invalid K3s release'
  [[ "$TIMEOUT" =~ ^[1-9][0-9]*$ ]] || die 'OCTELIUM_WAIT_TIMEOUT must be positive seconds'
  [[ "$DB_SIZE" =~ ^[1-9][0-9]*(Gi|Mi)$ ]] || die 'Invalid database size'
  [[ "$DB_DIR" == /* && "$DB_DIR" != / && "$DB_DIR" != *[\'\"\$\`\\]* && "$DB_DIR" != *$'\n'* ]] || die 'Invalid database directory'
  local image
  for image in "$PG_IMAGE" "$VALKEY_IMAGE" "$MULTUS_IMAGE"; do
    [[ "$image" =~ ^[A-Za-z0-9._/@:+-]+$ ]] || die "Invalid container image: $image"
  done
}

render() {
  # Only substitute manifest settings; preserve environment references in probes.
  envsubst '$NS $PG_APP $PG_SECRET_NAME $PG_PV_NAME $PG_PVC_NAME $PG_STORAGE_CLASS
    $VALKEY_APP $VALKEY_SECRET_NAME $MULTUS_APP $PRIORITY_CLASS $PG_IMAGE $VALKEY_IMAGE
    $MULTUS_IMAGE $PG_RUN_UID $PG_RUN_GID $VALKEY_RUN_UID $VALKEY_RUN_GID
    $PG_CPU_REQUEST $PG_MEMORY_REQUEST $VALKEY_CPU_REQUEST $VALKEY_MEMORY_REQUEST
    $MULTUS_CPU_REQUEST $MULTUS_MEMORY_REQUEST $CNI_CONF_DIR $CNI_BIN_DIR $MULTUS_CONF_DIR $DB_DIR
    $DB_SIZE $NODE_NAME $PG_PASSWORD $VALKEY_SECRET_PASSWORD $VALKEY_CONFIG_REVISION' <"$SCRIPT_DIR/kubernetes/$1.yaml"
}

install_dependencies() {
  local command missing=false
  for command in curl openssl ip envsubst flock iptables psql pgrep; do
    command -v "$command" >/dev/null || missing=true
  done
  if $missing; then
    log 'Installing host tools (no host PostgreSQL server or Helm)'
    as_root apt-get update -qq
    as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
      ca-certificates curl openssl iproute2 gettext-base util-linux iptables postgresql-client procps
  fi
}

install_cli() {
  local missing=false command
  for command in octops octelium octeliumctl; do
    command -v "$command" >/dev/null || missing=true
  done
  if [[ "${OCTELIUM_SKIP_CLI_INSTALL:-false}" != true ]] && { $missing || [[ ! -f "$STATE_DIR/cli-installed" ]]; }; then
    log 'Installing Octelium CLIs'
    download https://octelium.com/install.sh -o "$TMP_DIR/install-cli.sh"
    local cli_version=
    if [[ "$VERSION" != latest ]]; then cli_version=v${VERSION#v}; fi
    as_root env INSTALL_DIR=/usr/local/bin USE_SUDO=false VERSION="$cli_version" bash "$TMP_DIR/install-cli.sh"
    touch "$STATE_DIR/cli-installed"
  fi
  for command in octops octelium octeliumctl; do
    command -v "$command" >/dev/null || die "$command is missing; remove $STATE_DIR/cli-installed and rerun"
  done
}

install_k3s() {
  command -v k3s >/dev/null && return 0
  # Download the official release binary: it embeds kubectl and containerd and
  # can run without the service manager required by get.k3s.io.
  local arch binary release_url checksum
  case "$(uname -m)" in
    x86_64) arch=amd64; binary=k3s ;;
    aarch64|arm64) arch=arm64; binary=k3s-arm64 ;;
    *) die 'Only amd64 and arm64 are supported' ;;
  esac
  if [[ -z "$K3S_VERSION" ]]; then
    release_url=$(download -o /dev/null -w '%{url_effective}' https://update.k3s.io/v1-release/channels/stable)
    K3S_VERSION=${release_url##*/}
  fi
  [[ "$K3S_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+\+k3s[0-9]+$ ]] || die "Could not resolve K3s stable release: $K3S_VERSION"
  release_url=https://github.com/k3s-io/k3s/releases/download/${K3S_VERSION//+/%2B}
  log "Installing K3s $K3S_VERSION"
  download "$release_url/$binary" -o "$TMP_DIR/$binary"
  download "$release_url/sha256sum-$arch.txt" -o "$TMP_DIR/k3s.sha256"
  checksum=$(awk -v binary="$binary" '$2 == binary {print $1}' "$TMP_DIR/k3s.sha256")
  [[ "$checksum" =~ ^[a-f0-9]{64}$ ]] || die 'K3s checksum was not found'
  (cd "$TMP_DIR"; printf '%s  %s\n' "$checksum" "$binary" | sha256sum -c -)
  as_root install -m 755 "$TMP_DIR/$binary" /usr/local/bin/k3s
  if ! command -v kubectl >/dev/null; then as_root ln -s k3s /usr/local/bin/kubectl; fi
}

api_ready() { kc --request-timeout=5s get --raw=/readyz >/dev/null 2>&1; }
start_k3s() {
  if ! api_ready; then
    # Avoid a second server when an existing process is still starting.
    if ! as_root pgrep -f '^(/[^ ]*/)?k3s server( |$)' >/dev/null; then
      log 'Starting K3s with its bundled containerd'
      as_root mount --make-rshared /
      touch "$STATE_DIR/k3s.log" "$STATE_DIR/k3s.pid"
      as_root bash -c 'log=$1; pid=$2; shift 2; nohup "$@" >>"$log" 2>&1 </dev/null 9>&- & echo $! >"$pid"' \
        _ "$STATE_DIR/k3s.log" "$STATE_DIR/k3s.pid" "$(command -v k3s)" server \
        --disable=traefik --disable=metrics-server \
        --secrets-encryption --write-kubeconfig-mode=0600 \
        --kubelet-arg=cgroup-driver=cgroupfs
    fi
    local deadline=$((SECONDS + TIMEOUT))
    until api_ready; do
      (( SECONDS < deadline )) || die "K3s did not become ready; inspect $STATE_DIR/k3s.log"
      sleep 2
    done
  fi
  kc wait --for=condition=Ready nodes --all --timeout="${TIMEOUT}s"
  export NODE_NAME
  NODE_NAME=$(kc get nodes -o jsonpath='{.items[0].metadata.name}')
  [[ -n "$NODE_NAME" ]] || die 'K3s did not register a node'
  as_root cat /etc/rancher/k3s/k3s.yaml >"$STATE_DIR/kubeconfig"
  export KUBECONFIG=$STATE_DIR/kubeconfig
  if [[ ! -d "$CNI_BIN_DIR" ]]; then
    CNI_BIN_DIR=$(as_root readlink -f /var/lib/rancher/k3s/data/current)/bin
    [[ -d "$CNI_BIN_DIR" ]] || die 'Could not find the K3s CNI binaries'
  fi
}

configure_node() {
  local gateway_ip=${OCTELIUM_GATEWAY_IP:-}
  if [[ -z "$gateway_ip" ]]; then
    gateway_ip=$(ip -4 route get 1.1.1.1 | awk '{for (i=1;i<NF;i++) if ($i == "src") {print $(i+1); exit}}')
  fi
  [[ "$gateway_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die 'Could not detect the local gateway IPv4; set OCTELIUM_GATEWAY_IP'
  ip -4 -o addr show | awk '{print $4}' | cut -d/ -f1 | grep -Fxq "$gateway_ip" || die 'OCTELIUM_GATEWAY_IP must be assigned to this Codespace'
  export OCTELIUM_REGION_EXTERNAL_IP=$gateway_ip
  kc label node "$NODE_NAME" --overwrite octelium.com/node= \
    octelium.com/node-mode-controlplane= octelium.com/node-mode-dataplane=
  kc annotate node "$NODE_NAME" --overwrite "octelium.com/override-gw-ip=$gateway_ip"
  kc taint node "$NODE_NAME" node-role.kubernetes.io/control-plane- >/dev/null 2>&1 || true
  kc taint node "$NODE_NAME" node-role.kubernetes.io/master- >/dev/null 2>&1 || true
  log "Using local gateway $gateway_ip on node $NODE_NAME"
}

credential() {
  local secret=$1 file=$2 value
  value=$(kc -n default get secret "$secret" --ignore-not-found -o jsonpath='{.data.password}') || return $?
  if [[ -n "$value" ]]; then
    value=$(printf '%s' "$value" | base64 -d) || return $?
  elif [[ -s "$file" ]]; then
    value=$(cat "$file")
  else
    value=$(openssl rand -hex 24)
  fi
  # Generated passwords are hex; reject unsafe YAML/config characters on reuse.
  [[ "$value" =~ ^[A-Za-z0-9+/=_-]+$ ]] || die "Invalid or empty password in $secret"
  printf '%s' "$value" >"$file"
  printf '%s' "$value"
}

install_datastores() {
  local existing_path existing_class
  existing_class=$(kc -n default get pvc "$PG_PVC_NAME" --ignore-not-found -o jsonpath='{.spec.storageClassName}')
  [[ -z "$existing_class" || "$existing_class" == "$PG_STORAGE_CLASS" ]] || die 'Legacy PostgreSQL PVC found. Use a fresh Codespace; see README migration notes.'
  existing_path=$(kc get pv "$PG_PV_NAME" --ignore-not-found -o jsonpath='{.spec.local.path}')
  [[ -z "$existing_path" || "$existing_path" == "$DB_DIR" ]] || die "Existing PostgreSQL PV points at $existing_path, not $DB_DIR"
  if as_root test -f "$DB_DIR/pgdata/PG_VERSION"; then
    [[ "$(as_root cat "$DB_DIR/pgdata/PG_VERSION")" == 17 ]] || die 'Database is not PostgreSQL 17; a major-version migration is required'
    [[ -s "$STATE_DIR/postgres-password" ]] || kc -n default get secret "$PG_SECRET_NAME" >/dev/null || die 'Existing database password is missing; restore installer state'
  fi
  export PG_PASSWORD VALKEY_SECRET_PASSWORD VALKEY_CONFIG_REVISION
  PG_PASSWORD=$(credential "$PG_SECRET_NAME" "$STATE_DIR/postgres-password")
  VALKEY_SECRET_PASSWORD=$(credential "$VALKEY_SECRET_NAME" "$STATE_DIR/valkey-password")
  VALKEY_CONFIG_REVISION=$(printf '%s' "$VALKEY_SECRET_PASSWORD" | sha256sum | cut -d' ' -f1)
  as_root install -d -m 750 -o "$PG_RUN_UID" -g "$PG_RUN_GID" "$DB_DIR"
  render datastores >"$TMP_DIR/datastores.yaml"
  kc apply -f "$TMP_DIR/datastores.yaml"
  kc -n default rollout status "statefulset/$PG_APP" --timeout="${TIMEOUT}s"
  kc -n default rollout status "deployment/$VALKEY_APP" --timeout="${TIMEOUT}s"
  # pg_isready does not authenticate: check the actual bootstrap credentials too.
  kc -n default exec "statefulset/$PG_APP" -- sh -ec \
    'PGPASSWORD="$POSTGRES_PASSWORD" psql -h 127.0.0.1 -U "$POSTGRES_USER" -d octelium -v ON_ERROR_STOP=1 -Atc "SELECT 1"' | grep -qx 1
  kc -n default exec "deployment/$VALKEY_APP" -- sh -ec \
    'valkey-cli --no-auth-warning -a "$VALKEY_PASSWORD" ping' | grep -qx PONG
}

install_multus() {
  render multus >"$TMP_DIR/multus.yaml"
  kc apply -f "$TMP_DIR/multus.yaml"
  kc -n kube-system rollout status "daemonset/$MULTUS_APP" --timeout="${TIMEOUT}s"
  local deadline=$((SECONDS + TIMEOUT))
  until as_root test -x "$CNI_BIN_DIR/multus" && \
    { as_root test -s "$CNI_CONF_DIR/00-multus.conf" || as_root test -s "$CNI_CONF_DIR/00-multus.conflist"; } && \
    as_root test -s "$CNI_CONF_DIR/multus.d/multus.kubeconfig"; do
    (( SECONDS < deadline )) || die 'Multus did not install its binary, config, and kubeconfig'
    sleep 2
  done
}

bootstrap() {
  if [[ -f "$STATE_DIR/bootstrapped" ]]; then
    kc get namespace octelium >/dev/null || die 'Octelium namespace is missing; installer state belongs to another cluster'
    log 'Reusing the initialized Octelium cluster'
  else
    cat >"$TMP_DIR/bootstrap.yaml" <<EOF
spec:
  cni:
    multusConfDir: '$MULTUS_CONF_DIR'
  primaryStorage:
    postgresql:
      username: octelium
      password: '$PG_PASSWORD'
      host: $PG_APP.default.svc
      database: octelium
      port: 5432
  secondaryStorage:
    redis:
      password: '$VALKEY_SECRET_PASSWORD'
      host: $VALKEY_APP.default.svc
      port: 6379
  network:
    quicv0:
      enable: true
EOF
    log 'Initializing Octelium'
    OCTELIUM_AUTH_TOKEN_SAVE_PATH="$STATE_DIR/init-token" \
      timeout "${TIMEOUT}s" octops init "$DOMAIN" --version "$VERSION" --bootstrap - <"$TMP_DIR/bootstrap.yaml"
    [[ -s "$STATE_DIR/init-token" ]] || die 'octops did not save the initial auth token'
    touch "$STATE_DIR/bootstrapped"
  fi
  kc -n octelium rollout status daemonset/octelium-gwagent --timeout="${TIMEOUT}s"
  kc wait "node/$NODE_NAME" --for=jsonpath='{.metadata.labels.octelium\.com/gateway-registered}'=true --timeout="${TIMEOUT}s"
  local deployment
  for deployment in svc-default-octelium-api svc-auth-octelium-api octelium-ingress-dataplane octelium-ingress; do
    kc -n octelium rollout status "deployment/$deployment" --timeout="${TIMEOUT}s"
  done
}

configure_shell() {
  # Keep TLS relaxation scoped to Octelium's localhost playground, never ~/.curlrc.
  printf 'export PATH=/usr/local/bin:$PATH\nexport OCTELIUM_DOMAIN=localhost\nexport OCTELIUM_INSECURE_TLS=true\nexport KUBECONFIG=%q\n' "$STATE_DIR/kubeconfig" >"$STATE_DIR/env.sh"
  local rc line
  printf -v line '[ ! -f %q ] || . %q' "$STATE_DIR/env.sh" "$STATE_DIR/env.sh"
  for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
    [[ -f "$rc" ]] || continue
    grep -Fxq "$line" "$rc" || printf '\n%s\n' "$line" >>"$rc"
  done
}

main() {
  parse_args "$@"
  if $PRINT_MANIFESTS; then
    command -v envsubst >/dev/null || die '--print-manifests requires envsubst (package gettext-base)'
    export NODE_NAME=playground PG_PASSWORD=preview-postgres VALKEY_SECRET_PASSWORD=preview-valkey VALKEY_CONFIG_REVISION=preview
    render datastores
    printf '\n---\n'
    render multus
    return
  fi
  export PATH=/usr/local/bin:$PATH
  install_dependencies
  mkdir -p "$STATE_DIR"
  STATE_DIR=$(cd -- "$STATE_DIR" && pwd)
  chmod 700 "$STATE_DIR"
  exec 9>"$STATE_DIR/install.lock"
  flock -n 9 || die 'Another playground installation is running'
  TMP_DIR=$(mktemp -d)
  if [[ -f "$STATE_DIR/version" ]]; then
    [[ "$VERSION" == latest || "$VERSION" == "$(cat "$STATE_DIR/version")" ]] || die 'Use octops upgrade to change an existing cluster version'
    VERSION=$(cat "$STATE_DIR/version")
  else
    printf '%s' "$VERSION" >"$STATE_DIR/version"
  fi
  install_cli
  install_k3s
  start_k3s
  local cluster_uid
  cluster_uid=$(kc get namespace kube-system -o jsonpath='{.metadata.uid}')
  [[ -n "$cluster_uid" ]] || die 'Could not identify the Kubernetes cluster'
  if [[ -f "$STATE_DIR/cluster-uid" ]]; then
    [[ "$(cat "$STATE_DIR/cluster-uid")" == "$cluster_uid" ]] || die 'Installer state belongs to another Kubernetes cluster; use a fresh Codespace'
  else
    printf '%s' "$cluster_uid" >"$STATE_DIR/cluster-uid"
  fi
  configure_node
  install_datastores
  install_multus
  bootstrap
  configure_shell
  local deadline=$((SECONDS + TIMEOUT))
  until curl -q --insecure -sS --connect-timeout 3 --max-time 5 -o /dev/null https://localhost 2>/dev/null; do
    (( SECONDS < deadline )) || die 'Localhost HTTPS ingress did not become ready; inspect the K3s ServiceLB pods'
    sleep 2
  done
  if [[ ! -f "$STATE_DIR/logged-in" ]] || ! octeliumctl get service >/dev/null 2>&1; then
    octelium login --domain "$DOMAIN" --auth-token "$(cat "$STATE_DIR/init-token")"
    touch "$STATE_DIR/logged-in"
  fi
  octeliumctl apply --include-secret - >/dev/null <<EOF
kind: Secret
metadata:
  name: pg
spec:
  data:
    value: '$PG_PASSWORD'
EOF
  log "Cluster ready. Open a terminal or run: source $STATE_DIR/env.sh"
  log "K3s log: $STATE_DIR/k3s.log"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
