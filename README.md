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

```sh
# on control node
sudo cp ct.sh /usr/local/bin/ct

# show help
ct help
```

```
create               Create a container
destroy              Destroy a container
start                Start the container
stop                 Stop the container
restart              Restart the container
exec                 Execute command inside a container

migrate              Migrate a container to another node
backup               Backup the container
restore              Restore the container
update               Update a container

status               Get the container status
ip                   Get container IP address
ip6                  Get container IPv6 address

docker               Execute Docker commands inside a container
docker compose       Execute Docker Compose commands inside a container
docker apply         Pull and start Docker Compose services
docker install       Install Docker and Docker Compose

upload               Upload files to a container
download             Download files from a container

list                 List all containers
ping                 Ping a node

Flags:
--id <container_id>                Specify container ID
--name <container_name>            Specify container name
--memory <size_MB>                 Set memory size in MB (default: 512)
--cores <num_cores>                Set number of CPU cores (default: 2)
--bridge <bridge_interface>        Set bridge interface (default: vmbr0)
--disk-size <size_GB>              Set disk size in GB (default: 8)
--disk-location <location>         Set disk location (default: local-zfs)
--os <operating_system>            Set operating system (default: alpine)
--template-location <location>     Set template location (default: local)
--user-name <username>             Set username (default: hey)
--user-password <password>         Set user password (default: hey)
--user-sshkeys <ssh_keys>          Set user SSH keys (default: ~/.ssh/authorized_keys)
```

### VM Management (TODO)

```bash
./vm.sh list
````
