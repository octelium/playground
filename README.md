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
``