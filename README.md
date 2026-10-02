# Octelium Codespace Playground

Run a single-node Octelium cluster inside a GitHub Codespace and use `octelium`
and `octeliumctl` from its terminal. The cluster domain is `localhost` and the
gateway is the Codespace's own local IPv4 address. For a cluster you can access
from other machines, follow the [official quick installation guide](https://octelium.com/docs/octelium/latest/overview/quick-install).

## Install

1. Create a Codespace from this repository using **Code → Codespaces**. The included
   devcontainer runs privileged so K3s and the gateway can configure mounts and
   networking. It requests at least **2 CPUs and 4 GB RAM**. If you already have a
   Codespace, rebuild its container to pick up `.devcontainer/devcontainer.json`.
2. Run as the normal Codespace user:

   ```bash
   bash install.sh
   ```

   Installation takes a few minutes. The script uses `sudo` for host setup and
   reports Kubernetes errors when a workload fails to start.
3. Open a new terminal, or load the environment in your current one:

   ```bash
   source .state/env.sh
   octeliumctl get service
   octeliumctl get user
   octelium status
   ```

The installer follows the dependency setup in the
[official cluster installer](https://octelium.com/install-cluster.sh): one
PostgreSQL 17 pod with a retained 5 GiB local volume, one ephemeral Valkey pod
(using Octelium's Redis storage protocol), and upstream Multus. Small resource
requests keep them schedulable on a Codespace. K3s uses its bundled containerd;
Traefik and metrics-server are disabled. Helm and a host PostgreSQL server are
not needed. CoreDNS, local-path storage, and K3s ServiceLB remain available for
service containers and localhost ingress.

The node receives both Octelium control-plane and data-plane labels. Before
bootstrap, `octelium.com/override-gw-ip` explicitly sets the local gateway address,
`OCTELIUM_REGION_EXTERNAL_IP` sets the local ingress address, and `spec.cni.multusConfDir`
aligns the gateway's delegate configuration directory with upstream Multus. The
Multus DaemonSet separately uses K3s's CNI configuration and binary paths. This avoids advertising the Codespace's public
NAT address. QUIC is enabled on the cluster; clients use WireGuard by default.

## Rerun and configure

Run `bash install.sh` again after restarting the Codespace or fixing an install
failure. It starts K3s without systemd, reuses credentials and database storage,
and skips completed Octelium bootstrap. A successful run also logs in the current
user and applies the `pg` Secret used by the database example below.

Installer state, a private kubeconfig, and credentials live in the ignored
`.state/` directory. PostgreSQL data lives in `/mnt/octelium/playground-db`.
The devcontainer mounts K3s's data/configuration and PostgreSQL data in named
volumes; keep `.state/` together with those volumes. Deleting the Codespace deletes
its playground. Back up anything you want to keep before doing so.

You can pin releases on the first installation:

```bash
bash install.sh --version <octelium-release> --k3s-version <k3s-release>
```

Use `octops upgrade localhost` for an existing Octelium cluster; rerunning the
installer is not an upgrade operation. See `bash install.sh --help` for image,
storage, state, and timeout overrides. For example, to explicitly choose an IPv4
address assigned to the Codespace:

```bash
OCTELIUM_GATEWAY_IP=10.0.0.4 bash install.sh
```

To inspect the dependency manifests without installing anything (requires
`envsubst`, provided by `gettext-base`):

```bash
bash install.sh --print-manifests
```

## Troubleshooting and old installations

Inspect the server log and Kubernetes workloads:

```bash
tail -n 80 .state/k3s.log
source .state/env.sh
kubectl get pods -A -o wide
kubectl get events -A --field-selector=type=Warning --sort-by=.lastTimestamp
kubectl -n default logs statefulset/octelium-postgresql
kubectl -n default logs deployment/octelium-valkey
kubectl -n kube-system logs daemonset/octelium-multus
kubectl -n octelium logs daemonset/octelium-gwagent
```

Mount or networking permission errors usually mean the container needs rebuilding
with this repository's privileged devcontainer configuration. Workload scheduling
failures may require a larger Codespace.

For a Codespace that ran the old Bitnami/Helm installer, start with a fresh
Codespace. The new installer refuses a legacy PostgreSQL PVC or mismatched cluster
state and does not migrate or erase an existing database. The old script also
added `insecure` to `~/.curlrc`; remove that line if it is still present. The new
script scopes insecure TLS to Octelium's self-signed localhost certificate. Use
`curl --insecure` explicitly for the localhost examples below.

## Managing the Cluster

We recommend you to first read the quick guide about managing the _Cluster_ [here](https://octelium.com/docs/octelium/latest/overview/management) to get an idea of how the Cluster is managed. Furthermore, this repo has some Cluster configurations inside the directory `configs` that includes a few resources (e.g. _Services_, _Namespaces_, _Users_ and _Groups_). You can, for example, create and apply all these resources via the `octeliumctl apply` command as follows:

```bash
octeliumctl apply ./configs
```

You can also apply a certain sub-directory or even a single file as follows:

```bash
octeliumctl apply ./configs/services
# OR
octeliumctl apply ./configs/users/main.yaml
```

You can also read more about managing the _Cluster_ in the following guides:

- Managing _Services_ [here](https://octelium.com/docs/octelium/latest/management/core/service/overview)
- Secret-less access [here](https://octelium.com/docs/octelium/latest/management/core/service/secretless) to provide seamless access to APIs, databases and SSH servers without sharing API keys or passwords.
- Access control and _Policies_ [here](https://octelium.com/docs/octelium/latest/management/core/policy)
- Managing _Users_ [here](https://octelium.com/docs/octelium/latest/management/core/user).
- Managing _Namespaces_ [here](https://octelium.com/docs/octelium/latest/management/core/namespace).
- Managing _Groups_ [here](https://octelium.com/docs/octelium/latest/management/core/group).
- Managing _Secrets_ [here](https://octelium.com/docs/octelium/latest/management/core/secret).
- Managing _Credentials_ [here](https://octelium.com/docs/octelium/latest/management/core/credential).
- Dynamic _Service_ configuration and routing [here](https://octelium.com/docs/octelium/latest/management/core/service/dynamic-config).
- Client-less/BeyondCorp [here](https://octelium.com/docs/octelium/latest/management/core/service/clientless) and anonymous access [here](https://octelium.com/docs/octelium/latest/management/core/service/anonymous-access)
- Deploying _Services_ via managed containers [here](https://octelium.com/docs/octelium/latest/management/core/service/managed-containers).

You might also want to have a look on some examples:

- Zero trust access to SaaS PostgreSQL-based databases (e.g. NeonDB) [here](https://octelium.com/docs/octelium/latest/management/guide/service/databases/neon)
- Octelium as infrastructure for MCP [here](https://octelium.com/docs/octelium/latest/management/guide/service/ai/self-hosted-mcp)
- Octelium as ngrok alternative [here](https://octelium.com/docs/octelium/latest/management/guide/service/http/open-source-self-hosted-ngrok-alternative)
- Octelium as an API gateway [here](https://octelium.com/docs/octelium/latest/management/guide/service/http/api-gateway)
- Octelium as an AI gateway [here](https://octelium.com/docs/octelium/latest/management/guide/service/ai/ai-gateway)
- Deploying and hosting (both securely for authorized Users as well as anonymously) containerized Next.js/Vite/Astro web apps [here](https://octelium.com/docs/octelium/latest/management/guide/service/http/nextjs-vite)

## Accessing Services

### Client-based Mode

You can actually currently connect to the Cluster via the rootless gVisor mode and map the _Services_ you would like to use. Here is an example:

```bash
octelium connect --implementation gvisor -p nginx:8090 -p postgres-main:5432
```

Now you can access the protected `nginx` _Service_ which is mapped to the local machine's port `8090` as follows:

```bash
curl http://localhost:8090
```

And you can also access to the `postgres-main` PostgreSQL database in a secret-less way without having to know the database's password, which is actually the main store for the Octelium _Cluster_ itself, as follows:

```bash
psql -h localhost -p 5432 -U octelium -d octelium
```

You can play with the embedded SSH mode (read more [here](https://octelium.com/docs/octelium/latest/management/core/service/embedded-ssh)) where you can SSH into the Codespace (let's pretend that it is some remote container, machine, IoT, etc...) from within the Codespace machine.

```bash
octelium connect --implementation gvisor --essh -p essh:2022
```

You can get the name of your own _Session_ as follows:

```bash
octeliumctl get sess
```

And use the name to SSH into the Codespace as follows:

```bash
ssh -p 2022 root-abcdef@localhost
```

### Client-less Mode

You can also access HTTP-based Services via the client-less (i.e. BeyondCorp) mode simply by using Octelium access tokens as a standard bearer token (read more about _Credentials_ [here](https://octelium.com/docs/octelium/latest/management/core/credential)). You can, for example, directly create an access token _Credential_ as follows:

```bash
octeliumctl create cred cred01 --user root --policy allow-all --type access-token

# The output is something like
Access Token: AQpAoWCZWpulnpQMRF3Nj45...
```

And you can use the access token to access, for example, the protected `nginx` _Service_ defined in `configs/services/main.yaml` via `curl` as follows:

```bash
curl --insecure -H "Authorization: Bearer AQpAoWCZWpulnpQMRF3Nj45..." https://nginx.localhost

# Note that the Service FQDN is "nginx.localhost" because the Cluster domain is "localhost"
```

For anonymous _Services_ such as `nginx-anonymous` defined in `configs/services/main.yaml` you can publicly access it without using bearer authentication as follows:

```bash
curl --insecure https://nginx-anonymous.localhost
```


## Validate installer changes

Run the mocked installer regression checks without launching a cluster:

```bash
bash -n install.sh tests/install.sh
bash tests/install.sh
```

These checks cover fresh installation, credential reuse, local gateway selection,
dependency readiness and authentication failures, and rejection of legacy or
mismatched cluster state. They require `envsubst` from `gettext-base`. A real
Codespace install is needed to verify nested container networking end to end.
