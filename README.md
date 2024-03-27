# PEW - Proxmox Easy Wizard

Pew is a collection of shell scripts to easy manage proxmox containers and vms (soon).
The script copy itself on the proxmox host and runs all task directly on the host.
So no need for complicated API setup, or gui walkthroughs.

> NOTE: Highly opinionated to my needs. Check the scripts first, to get an idea whats happening!

## Setup PVE hosts

1. Run setup in TUI mode
2. Install with `zfs (RAID1)`
3. copy sshkey: `ssh-copy-id -i ~/.ssh/id_ed25519.pub root@pve1`

### Postsetup

Run the `init-pve.sh` script to initialize the proxmox host.

> Script will copy itself to proxmox host, no need to copy it to the host.

1. check if ssh connection is setup correctly

```bash
./init-pve.sh ping
```

2. Basic configuration (repos, user, tools, disable nag)

```bash
./init-pve.sh setup
```

3. Optional: setup gpu passthrought, only needed for VMs!

```bash
./init-pve.sh gpu
# to create a resource group
./init-pve.sh resgroup
```

## Container Management

The ct.sh allows to easy manage containers.

> The script copy itself to `/usr/local/bin/ct`. So it can run with `ct` on proxmox nodes

```
	Usage: ct.sh <action> [flags]

	Actions:
	ping                 Ping a specific node.
	list                 List all containers.
	create               Create a container. Flags:
	                        --id <id>                Container ID.
	                        --name <name>            Container name.
	                        --memory <memory>        Memory size in MB.
	                        --cores <cores>          Number of CPU cores.
	                        --bridge <bridge>        Network bridge name.
	                        --disk-size <size>       Disk size in GB.
	                        --disk-location <location> Disk storage location.
	                        --os <os>                Operating system.
	                        --template-location <location> Template location.
	                        --user-name <name>       User name.
	                        --user-password <password> User password.
	                        --user-sshkeys <keys>   User SSH keys.
	destroy              Destroy a container.
	update               Update a container.
	migrate              Migrate a container. Provide the target node.
	cexec                Execute a command inside a container.
	ip                   Show IP address of a container.
	docker               Execute a docker command inside a container.
	docker_compose       Execute a docker compose command inside a container.
	docker_update        Update docker images inside a container.
	docker_install       Install docker inside a container.
```

### VM Management (TODO)

```bash
./vm.sh list
````
