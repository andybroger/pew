#!/usr/bin/env bash
set -eo pipefail

### VARIABLES ###
HOST=${HOST:-"pve1"}
PRIMARY=${PRIMARY:-"pve1"}
NODES=${NODES:-"pve1 pve2 pve3"}

SSHKEY_PATH=${SSHKEY_PATH:-"$HOME/.ssh/id_ed25519.pub"}

### CONTAINER ###
CTID=${CTID:-""}
NAME=${NAME:-"ct"}
MEMORY="${MEMORY:-512}"
CORES="${CORES:-2}"
BRIDGE=${BRIDGE:-"vmbr0"}
DISK_SIZE=${DISK_SIZE:-"8"}
DISK_LOCATION=${DISK_LOCATION:-"local-zfs"}
OS=${OS:-"alpine"}
TEMPLATE_LOCATION=${TEMPLATE_LOCATION:-"local"}

### USER ###
USER_NAME=${USER_NAME:-"hey"}
USER_PASSWORD=${USER_PASSWORD:-"hey"}
USER_SSHKEYS=${USER_SSHKEYS:-""} # default: "$(cat $HOME/.ssh/authorized_keys)"



### COMMANDS ###
create() {
	create_flags "${@:2}"
	local ostemplate
	ostemplate=$(get_ostemplate)

	echo "Creating container $CTID with $ostemplate ..."

	pct create "$CTID" "$ostemplate" \
		--hostname "$NAME" \
		--cores "$CORES" \
		--memory "$MEMORY" \
		--swap 0 \
		--rootfs "$DISK_LOCATION:$DISK_SIZE" \
		--net0 name=eth0,bridge="$BRIDGE",ip=dhcp,ip6=auto \
		--mp0 /mnt/nas,mp=/mnt/nas,replicate=0,shared=1 \
		--ostype "$OS" \
		--unprivileged 1 \
		--features "nesting=1,keyctl=1" \
		--onboot 1

	# add gpu
	cat <<-EOF >>/etc/pve/lxc/"${CTID}".conf
		lxc.cgroup2.devices.allow: c 226:128 rwm
		lxc.mount.entry: /dev/dri/ dev/dri/ none bind,optional,create=dir 0 0
		lxc.hook.pre-start: sh -c "chown -R 0:101000 /dev/dri/"
	EOF

	# start container
	echo -n "Starting container..."
	ha-manager add "${CTID}" --state started
	# check if container is running
	while [[ $(pct status "$CTID" | grep "status" | awk '{print $2}') != "running" ]]; do
		echo -n "."
		sleep 1
	done
	echo " done."

	for i in "${!NODES[@]}"; do
		if [[ "${NODES[i]}" != "$HOST" ]]; then
			pvesr create-local-job "${CTID}"-"${i}" "${NODES[i]}" --schedule "*/5" --rate 10
		fi
	done

	case $OS in
	alpine) setup_alpine ;;
	debian|ubuntu) setup_debian ;;
	*) echo "No setup for $OS" ;;
	esac
}

create_flags() {
	while [[ $# -gt 0 ]]; do
		case $1 in
		--id)
			CTID="$2"
			shift 2
			;;
		--name)
			NAME="$2"
			shift 2
			;;
		--memory)
			MEMORY="$2"
			shift 2
			;;
		--cores)
			CORES="$2"
			shift 2
			;;
		--bridge)
			BRIDGE="$2"
			shift 2
			;;
		--disk-size)
			DISK_SIZE="$2"
			shift 2
			;;
		--disk-location)
			DISK_LOCATION="$2"
			shift 2
			;;
		--os)
			OS="$2"
			shift 2
			;;
		--template-location)
			TEMPLATE_LOCATION="$2"
			shift 2
			;;
		--user-name)
			USER_NAME="$2"
			shift 2
			;;
		--user-password)
			USER_PASSWORD="$2"
			shift 2
			;;
		--user-sshkeys)
			USER_SSHKEYS="$2"
			shift 2
			;;
		*)
			echo "Unknown option: $1"
			exit 1
			;;
		esac
	done
}

destroy() {
	pvesh delete /nodes/"$NODE"/lxc/"$CTID" --destroy-unreferenced-disks 1 --force 1 --purge 1
}

list() {
	pvesh get /cluster/resources --type vm --output-format=json \
		| jq -r '[.[] | {id, name, node, status}] | (.[0] | keys_unsorted) as $keys | map([.[ $keys[]]]) as $rows | $keys, $rows[] | @tsv' \
		| column -t \
		| grep "lxc/"
	exit 0
};

update() {
	echo "Updating container $CTID ..."
	local os
	os=$(get_os)

	if [ "$os" = "debian" ] || [ "$os" = "ubuntu" ]; then
		lxc-attach -n "$CTID" -- apt update
		lxc-attach -n "$CTID" -- "$ctid" apt upgrade -y
	elif [ "$os" = "alpine" ]; then
		lxc-attach -n "$CTID" -- apk update
		lxc-attach -n "$CTID" -- apk upgrade
	fi
}

ip () {
	# TODO: run on specific node
	CTID=$2
	[[ -z "$CTID" ]] && echo "Container ID is required." && exit 1
	pct exec "$CTID" -- ip a
}

migrate() {
	[[ -z "$CTID" ]] && echo "Container ID is required." && exit 1
	NODE=$2
	[[ -z "$NODE" ]] && echo "Node is required." && exit 1
	pct migrate "$CTID" "$NODE" --restart 1
}

cexec() {
	lxc-attach -n "$CTID" -- "${@:2}"
}

docker() {
	lxc-attach -n "$CTID" -- docker "${@:2}"
}

docker_compose() {
	[[ -z "$CTID" ]] && echo "Container ID is required." && exit 1
	lxc-attach -n "$CTID" -- docker compose "${@:2}"
}

docker_update() {
	lxc-attach -n "$CTID" -- docker compose pull
	lxc-attach -n "$CTID" -- docker compose up -d
}

docker_install() {
	local os
	os=$(get_os)

	if lxc-attach -n "$CTID" -- which docker &> /dev/null; then
		echo "Docker is already installed."
		exit 0
	fi

	echo -n "Installing docker on ${os}..."

	if [ "$os" = "alpine" ]; then
		lxc-attach -n "$CTID" -- apk add docker docker-compose &>/dev/null
		lxc-attach -n "$CTID" -- rc-update add docker boot &>/dev/null
		lxc-attach -n "$CTID" -- service docker start &>/dev/null
	else
		lxc-attach -n "$CTID" -- sh -c "curl -fsSL https://get.docker.com | sh &>/dev/null"
	fi
	echo " done."
}

ping() {
	NODE=$2
	[[ -z "$NODE" ]] && echo "Node is required." && exit 1
	ssh -q root@"${NODE}" -- echo "pong from \${HOSTNAME}, \$(pveversion)"
}

### SETUP FUNCTIONS ###

setup_alpine() {
	lxc-attach -n "$CTID" -- sh -c "echo \"https://dl-cdn.alpinelinux.org/alpine/v\$(cut -d. -f1,2 /etc/alpine-release)/main\" > /etc/apk/repositories"
	lxc-attach -n "$CTID" -- sh -c "echo \"https://dl-cdn.alpinelinux.org/alpine/v\$(cut -d. -f1,2 /etc/alpine-release)/community\" >> /etc/apk/repositories"
	lxc-attach -n "$CTID" -- sh -c "echo \"@testing https://dl-cdn.alpinelinux.org/alpine/edge/testing\" >> /etc/apk/repositories"
	lxc-attach -n "$CTID" -- sh -c "apk update"
	lxc-attach -n "$CTID" -- sh -c "apk upgrade"
	lxc-attach -n "$CTID" -- sh -c "apk add bash curl neovim git btop tree tmux net-tools jq"
	lxc-attach -n "$CTID" -- bash -c "setup-sshd -c openssh"
	lxc-attach -n "$CTID" -- bash -c "setup-user -a -u -k ${USER_SSHKEYS:-\"$(cat "$HOME"/.ssh/authorized_keys)\"} ${USER_NAME}"
	lxc-attach -n "$CTID" -- bash -c "setup-timezone -z Europe/Zurich"
	lxc-attach -n "$CTID" -- bash -c "echo ${USER_NAME}:${USER_PASSWORD} | chpasswd"
	lxc-attach -n "$CTID" -- bash -c "ln -s  /usr/bin/doas /usr/bin/sudo"
	lxc-attach -n "$CTID" -- bash -c "echo > /etc/motd"
}

setup_debian() {
	lxc-attach -n "$CTID" -- "apt update &>/dev/null && apt dist-upgrade -y &>/dev/null"
	lxc-attach -n "$CTID" -- "apt install -y openssh-server sudo bash curl neovim git btop tree tmux net-tools jq &>/dev/null"
	lxc-attach -n "$CTID" -- "systemctl enable --now ssh &>/dev/null"
	lxc-attach -n "$CTID" -- "adduser --disabled-password --gecos '' ${USER_NAME} &>/dev/null"
	lxc-attach -n "$CTID" -- "echo ${USER_NAME}:${USER_PASSWORD} | chpasswd &>/dev/null"
	lxc-attach -n "$CTID" -- "echo '${USER_NAME} ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/${USER_NAME}"
	lxc-attach -n "$CTID" -- "mkdir -p /home/${USER_NAME}/.ssh"
	lxc-attach -n "$CTID" -- "echo '${SSHKEY}' > /home/${USER_NAME}/.ssh/authorized_keys"
	lxc-attach -n "$CTID" -- "chown -R ${USER_NAME}:${USER_NAME} /home/${USER_NAME}/.ssh"
	lxc-attach -n "$CTID" -- "chmod 700 /home/${USER_NAME}/.ssh"
	lxc-attach -n "$CTID" -- "chmod 600 /home/${USER_NAME}/.ssh/authorized_keys"
}

### HELPER FUNCTIONS ###

get_ostemplate() {
	match=$(pveam available --section system | grep "$OS")
	[[ -z "$match" ]] && echo "No matching image found for $OS" && exit 1
	local ostemplate
	ostemplate=$(echo "$match" | awk '{print $2}' | sort -r | head -n1)
	pveam download "$TEMPLATE_LOCATION" "$ostemplate" &>/dev/null
	echo "$TEMPLATE_LOCATION:vztmpl/$ostemplate"
}

get_os() {
	local os
	os=$(lxc-attach -n "$CTID" -- cat /etc/os-release | grep "^ID=" | cut -d= -f2)
	[[ -z "$os" ]] && echo "Could not determine OS." && exit 1
	echo "$os"
}

check_ssh_key() {
	if ! ssh -o BatchMode=yes -o ConnectTimeout=5 root@"${HOST}" 'exit'; then
		ssh-copy-id -i "${SSHKEY_PATH}" root@"${HOST}"
	fi
}

get_id() {
	local ctid

	if [[ "$TARGET" =~ ^[0-9] ]]; then
		ctid="$TARGET"
	else
		ctid=$(ssh -q root@"${HOST}" -- pvesh get /cluster/resources --output-format json --type vm | jq -r ".[] | select(.name == \"$TARGET\") | .vmid")
	fi

	if [[ -z "$ctid" && "$ACTION" == "create" ]]; then
		ctid="$(ssh -q root@"${HOST}" -- "pvesh get /cluster/nextid")"
	fi

	echo "$ctid"
}

get_node() {
	# if target is a number, get the node from the ID
	if [[ "$TARGET" =~ ^[0-9] ]]; then
		NODE=$(ssh -q root@"${HOST}" -- pvesh get /cluster/resources --output-format json --type vm | jq -r ".[] | select(.vmid == $TARGET) | .node")
	else
		NODE=$(ssh -q root@"${HOST}" -- pvesh get /cluster/resources --output-format json --type vm | jq -r ".[] | select(.name == \"$TARGET\") | .node")
	fi
	NODE=${NODE:-$HOST}
	echo "$NODE"
}

is_proxmox() {
	command -v pveversion &>/dev/null
}

run() {
	shift 2
	CTID="$(get_id)"

	if [[ -z "$CTID" && "$ACTION" != "list" ]]; then
		echo "Container $TARGET not found."
		exit 1
	fi

	NAME=${TARGET:-"ct$CTID"}
	NODE="$(get_node)"

	if [[ "$NODE" != "$HOSTNAME" ]]; then
		scp "$0" root@"${NODE}":/usr/local/bin/ct 1>/dev/null
		ssh -qt root@"${NODE}" -- ct "$ACTION" "$@"
	else
		echo -n "Running $ACTION via $NODE"
		echo " on container $NAME ($CTID)"
		$ACTION "$@"
	fi
}

usage() {
	cat <<-EOF
	Usage: $0 <action> [flags]

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

	EOF
}

### PARAMS ###
ACTION=$1
TARGET=$2
# split NODES into array
IFS=" " read -r -a NODES <<<"$NODES"

[[ -z "$ACTION" ]] && usage

case ${ACTION} in
	ping) run ping "$@" ;;
	create) run create "$@";;
	destroy) run destroy "$@";;
	list) run list "$@";;
	update) run update "$@";;
	migrate) run migrate "$@";;
	cexec) run cexec "$@";;
	ip) run ip "$@";;
	docker) run docker "$@";;
	docker_compose) run docker_compose "$@";;
	docker_update) run docker_update "$@";;
	docker_install) run docker_install "$@";;
	*) echo "unknown action: $ACTION"; usage;;
esac
