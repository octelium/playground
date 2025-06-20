# Octelium Codespace Playground

## What is this?

This is a playground for you to install, run and manage an Octelium Cluster from within a GitHub Codespace. While we recommend you to install a demo Cluster over a cheap cloud instance (e.g. DigitalOcean, Vultr, EC2, Hetzner, etc...) or from within a Linux VM/microVM, this can be another way for you to play with Octelium without having to install it. Note the Cluster domain in our case here is going to be simply `localhost`.


## Steps

1. Run the current Repo in a Codespace via the green "Code" button on top of this page. You might probably also need to wait a minute or 2 after the Codespace is initialized since the microVM host CPUs are usually busy at startup. This has nothing to do with this repo or Octelium. It's just due to Codespace's heavy CPU usage upon initialization.

2. Run the `install.sh` script as follows:

```bash
sudo chmod 755 ./install.sh
./install.sh
```


This script will take a few minutes to complete depending on the Codespace's machine type (i.e. how much RAM and vCPUs it has).

3. Open a new terminal tab and start running `octeliumctl` commands:

```bash
octeliumctl get service
#Or simply
octeliumctl get svc
```


## Managing the Cluster

We recommend you to first read the quick guide managing the _Cluster_ [here](https://octelium.com/docs/octelium/latest/overview/management) to understand how the Cluster is managed. Furthermore, this repo has some Cluster configurations inside the directory `configs`. You can, for example, apply all these resources via the `octeliumctl apply` command as follows:

```bash
octeliumctl apply ./configs
```

You can also apply a certain sub-directory or even a single file as follows:

```bash
octeliumctl apply ./configs/services
# OR
octeliumctl apply ./configs/users/main.yaml 
```


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

You can also access HTTP-based Services via the client-less (i.e. BeyondCorp) mode simply by using Octelium access tokens as a standard bearer token. You can, for example, directly create an access token _Credential_ as follows:


```bash
octeliumctl create cred cred01 --user root --policy allow-all --type access-token
```

And you can use the access token to access, for example, the protected `nginx` _Service_ via `curl` as follows:

```bash
curl -k -H "Authorization: Bearer <ACCESS_TOKEN>" https://nginx.localhost
```