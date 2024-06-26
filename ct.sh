#!/usr/bin/env bash
set -eo pipefail

HOST=${HOST:-"pve1"}
PRIMARY=${PRIMARY:-"pve1"}
NODES=${NODES:-"pve1 pve2 pve3"}
SSHKEY_PATH=${SSHKEY_PATH:-"$HOME/.ssh/id_ed25519.pub"}
CTID=${CTID:-""}
NAME=${NAME:-"ct"}
MEMORY="${MEMORY:-512}"
CORES="${CORES:-2}"
BRIDGE=${BRIDGE:-"vmbr0"}
DISK_SIZE=${DISK_SIZE:-"8"}
DISK_LOCATION=${DISK_LOCATION:-"local-zfs"}
OS=${OS:-"alpine"}
TEMPLATE_LOCATION=${TEMPLATE_LOCATION:-"local"}
USER_NAME=${USER_NAME:-"hey"}
USER_PASSWORD=${USER_PASSWORD:-"hey"}
USER_SSHKEYS=${USER_SSHKEYS:-""}

create() {
	parse_flags "${@:2}"
	local ostemplate
	ostemplate=$(get_ostemplate)

	echo "Creating container $CTID ($NAME) with $ostemplate on $NODE ..."
	echo "Cores: $CORES Memory: $MEMORY MB Disk: $DISK_SIZE GB Bridge: $BRIDGE"

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

	echo -n "Starting container..."
	ha-manager add "${CTID}" --state started
	while [[ $(pct status "$CTID" | grep "status" | awk '{print $2}') != "running" ]]; do
		echo -n "."
		sleep 1
	done
	echo " done."

	# create replication jobs
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

destroy() {
	# TODO: convert to pct
	pvesh delete /nodes/"$NODE"/lxc/"$CTID" --destroy-unreferenced-disks 1 --force 1 --purge 1
}

update() {
	local os
	os=$(get_os)

	if [ "$os" = "debian" ] || [ "$os" = "ubuntu" ]; then
		lxc-attach -n "$CTID" -- apt update
		lxc-attach -n "$CTID" -- apt upgrade -y
	elif [ "$os" = "alpine" ]; then
		lxc-attach -n "$CTID" -- apk update
		lxc-attach -n "$CTID" -- apk upgrade
	fi
}

ip () {
	lxc-attach -n "$CTID" -- ip a show eth0 | grep "inet " | awk '{print $2}' | cut -d/ -f1
}

ip6 () {
	lxc-attach -n "$CTID" -- ip a show eth0 | grep "inet6 " | awk '{print $2}' | cut -d/ -f1
}

migrate() {
	NODE=$2
	[[ -z "$NODE" ]] && echo "Node is required." && exit 1
	echo "Migrating $NAME ($CTID) to $NODE ..."
	pct migrate "$CTID" "$NODE" --restart 1
}

exec() {
	lxc-attach -n "$CTID" -- "${@:2}"
}

ct() {
	pct "$1" "$CTID" "${@:2}"
}

start() {
	pct start "$CTID"
}

stop() {
	pct stop "$CTID"
}

restart() {
	pct restart "$CTID"
}

status() {
	pct status "$CTID"
}

backup() {
	vzdump "$CTID" --mode snapshot --storage local --compress zstd --notification-policy never --notes-template "Backup of $NAME ($CTID)"
}

restore() {
	if [[ -z "$2" ]]; then
		echo "Backup file is required."
		echo "example: ct restore 100 /var/lib/vz/dump/vzdump-lxc-100-2021_08_01-00_00_01.tar.zst"
		exit 1
	fi
	read -p "Are you sure you want to restore $NAME ($CTID)? " -n 1 -r
	echo
	if [[ $REPLY =~ ^[Yy]$ ]]; then
		pct stop "$CTID" || true
		# wait for container to stop
		echo -n "Stopping container..."
		while [[ $(pct status "$CTID" | grep "status" | awk '{print $2}') != "stopped" ]]; do
			sleep 1
		done
		pct restore "$CTID" "${2}" --force --storage "${DISK_LOCATION}"
	fi
}

docker() {
	case $2 in
	compose) docker_compose "${@:3}" ;;
	apply) docker_apply "${@:3}" ;;
	edit) lxc-attach -n "$CTID" -- nvim /home/hey/docker-compose.yml ;;
	down) lxc-attach -n "$CTID" -- docker compose -f /home/hey/docker-compose.yml down ;;
	restart) lxc-attach -n "$CTID" -- docker compose -f /home/hey/docker-compose.yml restart ;;
	install) docker_install "${@:3}" ;;
	*) lxc-attach -n "$CTID" -- docker "${@:2}" ;;
	esac
}

docker_apply() {
	lxc-attach -n "$CTID" -- docker compose -f /home/hey/docker-compose.yml pull
	lxc-attach -n "$CTID" -- docker compose -f /home/hey/docker-compose.yml up -d
}

docker_install() {
	local os
	os=$(get_os)
	if lxc-attach -n "$CTID" -- which docker &> /dev/null; then
		echo "Docker is already installed."
		exit 0
	fi

	if [ "$os" = "alpine" ]; then
		lxc-attach -n "$CTID" -- apk add docker docker-compose
		lxc-attach -n "$CTID" -- rc-update add docker boot
		lxc-attach -n "$CTID" -- service docker start
	else
		lxc-attach -n "$CTID" -- sh -c "curl -fsSL https://get.docker.com | sh"
	fi
}

ping() {
	NODE=$2
	[[ -z "$NODE" ]] && echo "Node is required." && exit 1
	ssh -q root@"${NODE}" -- echo "pong from \${HOSTNAME}, \$(pveversion)"
	exit 0
}

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
	lxc-attach -n "$CTID" -- bash -c "apt update &>/dev/null && apt dist-upgrade -y"
	lxc-attach -n "$CTID" -- bash -c "apt install -y openssh-server sudo bash curl neovim git btop tree tmux net-tools jq"
	lxc-attach -n "$CTID" -- bash -c "systemctl enable --now ssh"
	lxc-attach -n "$CTID" -- bash -c "adduser --disabled-password --gecos '' ${USER_NAME}"
	lxc-attach -n "$CTID" -- bash -c "echo ${USER_NAME}:${USER_PASSWORD} | chpasswd"
	lxc-attach -n "$CTID" -- bash -c "echo '${USER_NAME} ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/${USER_NAME}"
	lxc-attach -n "$CTID" -- bash -c "mkdir -p /home/${USER_NAME}/.ssh"
	lxc-attach -n "$CTID" -- bash -c "echo '${USER_SSHKEYS:-\"$(cat "$HOME"/.ssh/authorized_keys)\"}' > /home/${USER_NAME}/.ssh/authorized_keys"
	lxc-attach -n "$CTID" -- bash -c "chown -R ${USER_NAME}:${USER_NAME} /home/${USER_NAME}/.ssh"
	lxc-attach -n "$CTID" -- bash -c "chmod 700 /home/${USER_NAME}/.ssh"
	lxc-attach -n "$CTID" -- bash -c "chmod 600 /home/${USER_NAME}/.ssh/authorized_keys"
}

get_ostemplate() {
	match=$(pveam available --section system | grep "$OS")
	[[ -z "$match" ]] && exit 1
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

parse_flags() {
	while [[ $# -gt 0 ]]; do
		case $1 in
		--id) CTID="$2"; shift 2 ;;
		--name) NAME="$2"; shift 2 ;;
		--memory) MEMORY="$2"; shift 2 ;;
		--cores) CORES="$2"; shift 2 ;;
		--bridge) BRIDGE="$2"; shift 2 ;;
		--disk-size) DISK_SIZE="$2"; shift 2 ;;
		--disk-location) DISK_LOCATION="$2"; shift 2 ;;
		--os) OS="$2"; shift 2 ;;
		--template-location) TEMPLATE_LOCATION="$2"; shift 2 ;;
		--user-name) USER_NAME="$2"; shift 2 ;;
		--user-password) USER_PASSWORD="$2"; shift 2 ;;
		--user-sshkeys) USER_SSHKEYS="$2"; shift 2 ;;
		*) echo "Unknown option: $1"; exit 1 ;;
		esac
	done
}

upload() {
	CTID=$(get_id)
	NAME=${TARGET:-"ct$CTID"}
	scp "${@:3}" "${USER_NAME}"@"${NAME}":
}

download() {
	CTID=$(get_id)
	NAME=${TARGET:-"ct$CTID"}
	scp "${USER_NAME}"@"${NAME}":"${@:3}" .
}

list() {
	# pvesh get /cluster/resources --type vm --outputformat json \
	# | jq -r '[.[] | {id, name, node, status}] | (.[0] | keys_unsorted) as $keys | map([.[ $keys[]]]) as $rows | $keys, $rows[] | @tsv' \
	# | column -t \
	# | grep \"lxc/\"
	ssh -q root@"${HOST}" -- "pvesh get /cluster/resources --type vm --noborder 1"
	exit 0
};

run() {
	shift 2
	CTID="$(get_id)"
	NAME=${TARGET:-"ct$CTID"}
	NODE="$(get_node)"
	if [[ "$NODE" != "$HOSTNAME" ]]; then
		scp "$0" root@"${NODE}":/usr/local/bin/ct 1>/dev/null
		ssh -qt root@"${NODE}" -- /usr/local/bin/ct "$ACTION" "$@"
	else
		$ACTION "$@"
	fi
}

usage() {
	cat <<-EOF
	Usage: ct <command> [options]

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

	EOF
	exit 0
}

TARGET=$2
ACTION=$1
IFS=" " read -r -a NODES <<<"$NODES" # split string into array

[[ -z "$ACTION" ]] && usage

case ${ACTION} in
	ping) ping "$@" ;;
	list) list ;;
	help) usage ;;
	upload) upload "$@";;
	download) download "$@";;
	*) run $ACTION "$@" ;;
esac
