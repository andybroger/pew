#!/bin/bash
set -eo pipefail

LOCATION="${LOCATION:-local-zfs}"
MEMORY="${MEMORY:-2}"
CORES="${CORES:-2}"
PASSWORD="${PASSWORD:-hey}"
NAME="${NAME:-}"
DISK="${DISK:-8}"
BRIDGE="${BRIDGE:-vmbr0}"
REMOTE="${REMOTE:-}"
GPU="${GPU:-false}"
CONSOLE="${CONSOLE:-false}"
SNAPSHOT_NAME="${SNAPSHOT_NAME:-}"
IMAGE_URL=${IMAGE_URL:-"https://cloud.debian.org/cdimage/cloud/bookworm-backports/daily/latest/debian-12-backports-generic-amd64-daily.qcow2"}
CLOUDINIT_YAML="
#cloud-config

package_update: true
package_upgrade: true

packages:
  - curl
  - git
  - qemu-guest-agent
  - btop
  - tree
  - tmux

power_state:
  mode: reboot
  condition: True

runcmd:
  - systemctl enable --now qemu-guest-agent
"
CLOUDINIT_GPU_YAML="
  - DEBIAN_FRONTEND=noninteractive apt-get install -y linux-headers-\$(uname -r) dkms build-essential
  - git clone https://github.com/strongtz/i915-sriov-dkms.git /tmp/i915-sriov-dkms
  - sed -i \"s/@_PKGBASE@/i915-sriov-dkms/g\" /tmp/i915-sriov-dkms/dkms.conf
  - sed -i \"s/@PKGVER@/\$(uname -r | sed 's/-amd64\$//')/g\" /tmp/i915-sriov-dkms/dkms.conf
  - sed -i \"s/ -j\\\$(nproc)//g\" /tmp/i915-sriov-dkms/dkms.conf
  - dkms add /tmp/i915-sriov-dkms
  - dkms install -m i915-sriov-dkms -v \$(uname -r | sed 's/-amd64\$//') -k \$(uname -r) --force -j 1
  - sed -i \"/GRUB_CMDLINE_LINUX=/c\\GRUB_CMDLINE_LINUX=\\\"console=tty0 console=ttyS0,115200 earlyprintk=ttyS0,115200 consoleblank=0 intel_iommu=on iommu=pt i915.enable_guc=3\\\"\" /etc/default/grub
  - update-grub
  - update-initramfs -u
"

usage() {
	cat <<EOF
Usage: $0 [ACTION] [VMID] [OPTIONS]

Actions:
  create      Create a new VM with specified settings.
  destroy     Delete an existing VM and all its data.
  console     Open a console to the VM.
  start       Start a stopped VM.
  stop        Stop a running VM.
  shutdown    Safely power down the VM.
  reboot      Restart the VM.
  reset       Hard reset the VM.
  ip          Retrieve VM's IP addresses.
  status      Show current status of the VM.
  snapshot    Create a snapshot of the VM. Requires --snapshot-name.
  rollback    Rollback the VM to a snapshot. Requires --snapshot-name.
  delsnap     Delete a VM snapshot. Requires --snapshot-name.
  list        List all VMs.

Options:
  --name [NAME]               Set VM's name.
  --memory [MEMORY]           Set VM's RAM in GB. Default is 2.
  --cores [CORES]             Assign CPU cores to the VM. Default is 2.
  --gpu                       Assign a GPU to the VM.
  --disk [DISK]               Set VM's disk size in GB. Default is 8.
  --bridge [BRIDGE]           Set VM's bridge network. Default is vmbr0.
  --remote [REMOTE]           Specify remote Proxmox server.
  --password [PASSWORD]       Set VM's default password. Default is 'hey'.
  --location [LOCATION]       Set VM's storage location. Default is 'local-zfs'.
  --console				      Attach to the VM's console after creation.
  --snapshot-name [NAME]      Specify the name for snapshot, rollback, or delsnap actions.
EOF
	exit 1
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--name) NAME="$2"; shift 2;;
		--memory) MEMORY="$2"; shift 2;;
		--cores) CORES="$2"; shift 2;;
		--gpu) GPU=true; shift;;
		--disk) DISK="$2"; shift 2;;
		--bridge) BRIDGE="$2"; shift 2;;
		--remote) REMOTE="$2"; shift 2;;
		--password) PASSWORD="$2"; shift 2;;
		--location) LOCATION="$2"; shift 2;;
		--snapshot-name) SNAPSHOT_NAME="$2"; shift 2;;
		--console) CONSOLE=true; shift;;
		--help) usage;;
		*)
			if [[ -z "$ACTION" ]]; then
				ACTION="$1"
			elif [[ -z "$VMID" ]]; then
				VMID="$1"
			else
				echo "Unknown option: $1"
				usage
			fi
			shift
			;;
	esac
done

if [[ "$ACTION" == "snapshot" || "$ACTION" == "rollback" || "$ACTION" == "delsnap" ]]; then
	if [[ -z "$SNAPSHOT_NAME" ]]; then
		echo "Snapshot name is required."
		usage
	fi
fi

if [[ "$ACTION" == "list" ]]; then
	VMID=1
fi

if [[ -z "$ACTION" || -z "$VMID" ]]; then
	echo "Action and VMID are required."
	usage
fi

if ! command -v qm &> /dev/null && [ -z "$REMOTE" ]; then
	echo "Not running in a Proxmox environment. Please specify a host with --remote."
	usage
fi

execute_command() {
	local COMMAND="$1"
	if [[ -n "$REMOTE" ]]; then
		ssh -qt "$REMOTE" "$COMMAND"
	else
		eval "$COMMAND"
	fi
}

create_vm() {
	local status
    status=$(execute_command "qm status $VMID" | grep status | awk '{print $2}')
	if [[ "$status" != "" ]]; then
		echo "VM $VMID already exists."
		exit 1
	fi
	execute_command "curl -sSL $IMAGE_URL -o /tmp/${IMAGE_URL##*/}"
	execute_command "qm create $VMID \
		--memory (($MEMORY*1024)) --cores $CORES ${NAME:+--name \"$NAME\"} \
		--machine q35 --serial0 socket --vga serial0 \
		--bios ovmf --efidisk0 ${LOCATION}:1,efitype=4m \
		--net0 virtio,bridge=${BRIDGE} --agent enabled=1 --ipconfig0 ip=dhcp,ip6=auto \
		--hotplug network,disk,usb,cloudinit --ide2 ${LOCATION}:cloudinit \
		--scsihw virtio-scsi-pci --scsi0 ${LOCATION}:0,import-from=/tmp/${IMAGE_URL##*/} \
		--cipassword \"$PASSWORD\" --ciuser hey --sshkeys ~/.ssh/authorized_keys"
	execute_command "qm resize $VMID scsi0 ${DISK}G"
	# execute_command "ha-manager add vm:${VMID} --state started"
	[[ "$GPU" == "true" ]] && CLOUDINIT_YAML="$CLOUDINIT_YAML$CLOUDINIT_GPU_YAML"
	execute_command "echo '$CLOUDINIT_YAML' > /var/lib/vz/snippets/cloudinit.yaml"
	execute_command "qm set $VMID --cicustom vendor=local:snippets/cloudinit.yaml"
	[[ "$GPU" == "true" ]] && execute_command "qm set $VMID --hostpci0 mapping=igpu1,pcie=1"
	execute_command "qm start $VMID"
	echo "VM $VMID created and started successfully."
	[[ "$CONSOLE" == "true" ]] && execute_command "qm terminal $VMID"
}

destroy_vm() {
	execute_command "qm stop $VMID"
	execute_command "qm wait $VMID"
	execute_command "qm destroy $VMID --destroy-unreferenced-disks 1 --purge 1"
	echo "VM $VMID destroyed successfully."
}

get_ip() {
	IP=$(execute_command "pvesh get /nodes/localhost/qemu/$VMID/agent/network-get-interfaces --output-format=json | jq -r '.result[] | select(.name == \"eth0\") | .[\"ip-addresses\"][] | \"\(.[\"ip-address-type\"]): \(.[\"ip-address\"])\"'")
	echo "$IP"
}

get_status() {
	IP=$(execute_command "pvesh get /nodes/localhost/qemu/$VMID/agent/network-get-interfaces --output-format=json | jq -r '.result[] | select(.name == \"eth0\") | .[\"ip-addresses\"][] | \"\(.[\"ip-address-type\"]): \(.[\"ip-address\"])\"'")
	NAME=$(execute_command "pvesh get /nodes/localhost/qemu/$VMID/config --output-format=json | jq -r '.name'")
	STATUS=$(execute_command "pvesh get /nodes/localhost/qemu/$VMID/status/current --output-format=json | jq -r '.status'")
	echo "id: $VMID"
	echo "name: $NAME"
	echo "status: $STATUS"
	echo "$IP"
}


case "$ACTION" in
	create) create_vm;;
	destroy) destroy_vm;;
	console) execute_command "qm terminal $VMID";;
	start) execute_command "qm start $VMID";;
	stop) execute_command "qm stop $VMID";;
	shutdown) execute_command "qm shutdown $VMID";;
	reboot) execute_command "qm reboot $VMID";;
	reset) execute_command "qm reset $VMID";;
	ip) get_ip;;
	status) get_status;;
	snapshot) execute_command "qm snapshot $VMID $SNAPSHOT_NAME --vmstate 1";;
	rollback) execute_command "qm rollback $VMID $SNAPSHOT_NAME --start 1";;
	delsnap) execute_command "qm delsnapshot $VMID $SNAPSHOT_NAME";;
	listsnap) execute_command "qm listsnapshot $VMID";;
	list) execute_command "qm list";;
	*) usage;;
esac
