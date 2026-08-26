# Creating an Installer Bundle

## Prereq

On your machine, make sure you have [Makeself](https://makeself.io) and `unzip` installed

e.g.,
```
$ sudo apt install makeself unzip
```

## Unzip the Agent zip file
The zip file has been included to avoid needing git-lfs for large executable size

```
unzip grafana-agent-v0.44.2-linux-amd64.zip && rm grafana-agent-v0.44.2-linux-amd64.zip
```

## Creating the bundle

Makeself will bundle the target directory and run the startup/setup script you specify against it when a user runs the resulting bundle.

So, in this case, if you are in the current (`./`) directory, you'd run the following to create the executable bundle:

```
$ makeself ./ installer.sh "OpsVerse Agent Installer" ./setup.sh
```

This ^ command will bundle everything in `./` and create `installer.sh` 

When a user runs `installer.sh`, it will behind-the-scenes unbundle and execute "./setup.sh"

In this case, the executable bundle installer.sh has label "OpsVerse Agent Installer" - just a name it spits out when running

## End user

The end user can then run the distributed installer as:

```
$ sudo installer.sh -- [OPTIONS]
```
