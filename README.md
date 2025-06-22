# Octelium Codespace Playground

## What is this?

This is a playground for you to install, run and manage an Octelium Cluster inside a GitHub Codespace. While we recommend you to install a demo Cluster over a cheap cloud VM/VPS instance such as DigitalOcean, Vultr, EC2, Hetzner, etc... (read more in the quick installation guide [here](https://octelium.com/docs/octelium/latest/overview/quick-install)) or from within a Linux VM/microVM inside your local machine, this method serves as an additional way for you to play with Octelium and try managing it without having to install it on real machine or a Kubernetes cluster. Note the Cluster domain in our case here is going to be simply `localhost`.

## Steps

1. Run the current Repo in a Codespace via the green "Code" button on top of this page. You might probably also need to wait a minute or 2 after the Codespace is initialized since the microVM host CPUs are usually busy at startup. This has nothing to do with Octelium but due to Codespace's heavy CPU usage upon initialization.

2. Run the `install.sh` script as follows:

```bash
sudo chmod 755 ./install.sh
./install.sh
```

This script will take a few minutes to complete depending on the Codespace's machine type (i.e. how much RAM and vCPUs it has).

3. Open a new terminal tab in your VSCode and start running `octelium` or `octeliumctl` commands. Here are some examples:

```bash
octeliumctl get service
#Or simply
octeliumctl get svc

octeliumctl get user

octeliumctl create secret

octelium status
```

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
- Secret-less access [here](https://octelium.com/docs/octelium/latest/management/core/service/secretless) to provide seamless access to APIs, databases and SSH servers without sharing API keys or passwords, access control and _Policies_ [here](https://octelium.com/docs/octelium/latest/management/core/policy)
- Managing _Users_ [here](https://octelium.com/docs/octelium/latest/management/core/user).
- Managing _Namespaces_ [here](https://octelium.com/docs/octelium/latest/management/core/namespace).
- Managing _Groups_ [here](https://octelium.com/docs/octelium/latest/management/core/group).
- Managing _Secrets_ [here](https://octelium.com/docs/octelium/latest/management/core/secret).

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
octelium connect -p nginx:8090 -p pg:5432
```

Now you can access the protected `nginx` _Service_ which is mapped to the local machine's port `8090` as follows:

```bash
curl http://localhost:8090
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
curl -k -H "Authorization: Bearer AQpAoWCZWpulnpQMRF3Nj45..." https://nginx.localhost

# Note that the Service FQDN is "nginx.localhost" because the Cluster domain is "localhost"
```

For anonymous _Services_ such as `nginx-anonymous` defined in `configs/services/main.yaml` you can publicly access it without using bearer authentication as follows:

```bash
curl -k https://nginx-anonymous.localhost
```
