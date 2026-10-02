#!/usr/bin/env bash
# Exercise installer orchestration without starting Kubernetes or touching host state.
# These mocks are called by the sourced installer and deliberately use literal probe variables.
# shellcheck disable=SC2016,SC2329
set -Eeuo pipefail
REPO_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEST_ROOT=$(mktemp -d)
trap 'rm -rf -- "$TEST_ROOT"' EXIT
command -v envsubst >/dev/null || { echo 'Install gettext-base to run these tests' >&2; exit 1; }

setup_mock() {
  export TEST_STATE=$TEST_ROOT/$1
  mkdir -p "$TEST_STATE/bin" "$TEST_STATE/cni/multus.d"
  # shellcheck source=install.sh
  source "$REPO_DIR/install.sh"
  STATE_DIR=$TEST_STATE/state
  DB_DIR=$TEST_STATE/db
  CNI_BIN_DIR=$TEST_STATE/cni
  CNI_CONF_DIR=$TEST_STATE/cni
  MULTUS_CONF_DIR=$TEST_STATE/multus/net.d
  touch "$CNI_BIN_DIR/multus" "$CNI_CONF_DIR/00-multus.conf" "$CNI_CONF_DIR/multus.d/multus.kubeconfig"
  chmod +x "$CNI_BIN_DIR/multus"
  printf 'configured\n' >"$CNI_CONF_DIR/00-multus.conf"
  printf 'configured\n' >"$CNI_CONF_DIR/multus.d/multus.kubeconfig"
  cat >"$TEST_STATE/bin/octops" <<'MOCK'
#!/usr/bin/env bash
set -e
printf 'octops\n' >>"$TEST_STATE/trace"
cat >"$TEST_STATE/bootstrap.yaml"
printf 'test-token' >"$OCTELIUM_AUTH_TOKEN_SAVE_PATH"
MOCK
  chmod +x "$TEST_STATE/bin/octops"
  export PATH=$TEST_STATE/bin:$PATH
  install_dependencies() { :; }
  install_cli() { :; }
  install_k3s() { :; }
  start_k3s() { export NODE_NAME=playground; }
  configure_shell() { :; }
  ip() {
    if [[ "$*" == *route* ]]; then
      printf '1.1.1.1 via 10.0.0.1 dev eth0 src 10.0.0.4\n'
    else
      printf '2: eth0 inet 10.0.0.4/24 scope global eth0\n'
    fi
  }
  as_root() {
    if [[ "$1" == install ]]; then mkdir -p "$DB_DIR"; else "$@"; fi
  }
  kc() {
    printf 'kubectl %s\n' "$*" >>"$TEST_STATE/trace"
    if [[ "${1:-}" == -n ]]; then shift 2; fi
    case "$*" in
      'get namespace kube-system '*) printf '%s' "${MOCK_CLUSTER_UID:-cluster-one}" ;;
      'get secret '*jsonpath*)
        local file=$TEST_STATE/$3
        [[ ! -f "$file" ]] || base64 <"$file" ;;
      'get pvc '*) printf '%s' "${MOCK_PVC_CLASS:-}" ;;
      'get pv '*) : ;;
      'rollout status statefulset/'*) [[ "${MOCK_FAIL_DATABASE:-false}" != true ]] ;;
      'exec statefulset/'*) printf '%s\n' "${MOCK_PG_RESULT:-1}" ;;
      'exec deployment/'*) printf 'PONG\n' ;;
      'apply -f '*) cp "$3" "$TEST_STATE/$(basename "$3")" ;;
      *) : ;;
    esac
  }
  octelium() { printf 'login\n' >>"$TEST_STATE/trace"; }
  curl() { :; }
  octeliumctl() { if [[ "$1" == apply ]]; then cat >"$TEST_STATE/pg-secret.yaml"; fi; }
}

# Fresh install and a subsequent rerun use the same credentials and bootstrap once.
(
  setup_mock resume
  main
  cp "$STATE_DIR/postgres-password" "$TEST_STATE/original-password"
  cp "$STATE_DIR/postgres-password" "$TEST_STATE/octelium-pg"
  cp "$STATE_DIR/valkey-password" "$TEST_STATE/octelium-valkey"
  cleanup
  mv "$CNI_CONF_DIR/00-multus.conf" "$CNI_CONF_DIR/00-multus.conflist"
  main
  cmp "$STATE_DIR/postgres-password" "$TEST_STATE/original-password"
  [[ $(grep -cx octops "$TEST_STATE/trace") == 1 ]]
  [[ $(grep -cx login "$TEST_STATE/trace") == 1 ]]
  grep -Fq 'octelium.com/override-gw-ip=10.0.0.4' "$TEST_STATE/trace"
  grep -Fq "multusConfDir: '$MULTUS_CONF_DIR'" "$TEST_STATE/bootstrap.yaml"
  grep -Fq 'host: octelium-valkey.default.svc' "$TEST_STATE/bootstrap.yaml"
  grep -Fq -- "--multus-cni-conf-dir=$MULTUS_CONF_DIR" "$TEST_STATE/multus.yaml"
  grep -Fq 'gateway-registered' "$TEST_STATE/trace"
  grep -Fq '"$VALKEY_PASSWORD"' "$TEST_STATE/datastores.yaml"
  grep -Fq '"$POSTGRES_USER"' "$TEST_STATE/datastores.yaml"
  [[ $(stat -c '%a' "$STATE_DIR/postgres-password") == 600 ]]
  # Verify dependency readiness/authentication precede bootstrap.
  awk '/exec statefulset/ {pg=1} /exec deployment/ {cache=1} /^octops$/ {exit !(pg && cache)}' "$TEST_STATE/trace"
)
printf 'PASS: fresh install, local gateway, credentials and rerun\n'

# Run expected failures in an independent process so errexit remains active.
run_failure() {
  local scenario=$1 setting=$2 expected=$3
  export REPO_DIR TEST_ROOT
  export -f setup_mock
  if bash -c 'setup_mock "$1"; export "$2"; main' _ "$scenario" "$setting" >"$TEST_ROOT/$scenario.log" 2>&1; then
    printf 'FAIL: %s unexpectedly succeeded\n' "$scenario" >&2
    exit 1
  fi
  [[ ! -f "$TEST_ROOT/$scenario/bootstrap.yaml" ]]
  grep -Fq "$expected" "$TEST_ROOT/$scenario.log"
  printf 'PASS: %s stops before bootstrap\n' "$scenario"
}
run_failure datastore-failure MOCK_FAIL_DATABASE=true 'Installation failed'
run_failure wrong-password MOCK_PG_RESULT=0 'Installation failed'
run_failure legacy-pvc MOCK_PVC_CLASS=local-path 'Legacy PostgreSQL PVC found'
run_failure invalid-gateway OCTELIUM_GATEWAY_IP=203.0.113.1 'must be assigned to this Codespace'

(
  setup_mock identity
  mkdir -p "$STATE_DIR"
  printf 'cluster-old' >"$STATE_DIR/cluster-uid"
)
run_failure identity MOCK_CLUSTER_UID=cluster-new 'belongs to another Kubernetes cluster'

# An unavailable Kubernetes API must not cause new credentials to be generated.
(
  setup_mock credential-error
  mkdir -p "$STATE_DIR"
  kc() { return 1; }
  if credential octelium-pg "$STATE_DIR/password"; then exit 1; fi
  [[ ! -e "$STATE_DIR/password" ]]
)
printf 'PASS: credential lookup failures preserve state\n'
