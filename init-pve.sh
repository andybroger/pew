#!/usr/bin/env bash

ACTION=${1:-}
HOST=${2:-"pve1"}
USER_NAME=${3:-"hey"}
USER_PASSWORD=${4:-"hey"}
SSHKEY_PATH=${5:-"$HOME/.ssh/id_ed25519.pub"}

setup() {
	# fix debian repos
	echo -n "Fixing Debian repos..."
	cat <<-EOF >/etc/apt/sources.list
	deb http://deb.debian.org/debian bookworm main contrib
	deb http://deb.debian.org/debian bookworm-updates main contrib
	deb http://security.debian.org/debian-security bookworm-security main contrib
	EOF
	echo 'APT::Get::Update::SourceListWarnings::NonFreeFirmware "false";' >/etc/apt/apt.conf.d/no-bookworm-firmware.conf
	echo " done."

	# disable enterprise repo
	echo -n "Disabling enterprise repo..."
	cat <<-EOF >/etc/apt/sources.list.d/pve-enterprise.list
	# deb https://enterprise.proxmox.com/debian/pve bookworm pve-enterprise
	EOF
	echo " done."

	# add no-subscription repo
	echo -n "Adding no-subscription repo..."
	cat <<-EOF >/etc/apt/sources.list.d/pve-no-subscription.list
	deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription
	EOF
	echo " done."

	# add ceph repo, disabled by default
	echo -n "Adding disabled ceph repos..."
	cat <<-EOF >/etc/apt/sources.list.d/ceph.list
	# deb http://download.proxmox.com/debian/ceph-quincy bookworm enterprise
	# deb http://download.proxmox.com/debian/ceph-quincy bookworm no-subscription
	# deb http://download.proxmox.com/debian/ceph-reef bookworm enterprise
	# deb http://download.proxmox.com/debian/ceph-reef bookworm no-subscription
	EOF
	echo " done."

	# disable # disable nag screen
	if [ ! -e /etc/apt/apt.conf.d/no-nag-script ]; then
		echo -n "Disabling nag screen..."
		echo "DPkg::Post-Invoke { \"dpkg -V proxmox-widget-toolkit | grep -q '/proxmoxlib\.js$'; if [ \$? -eq 1 ]; then { echo 'Removing subscription nag from UI...'; sed -i '/.*data\.status.*{/{s/\!//;s/active/NoMoreNagging/}' /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js; }; fi\"; };" >/etc/apt/apt.conf.d/no-nag-script
		apt --reinstall install proxmox-widget-toolkit &>/dev/null
		echo " done."
	fi

	# install updates
	echo -n "Update system..."
	apt-get update &>/dev/null
	apt-get -y dist-upgrade
	echo " done."

	# install packages
	echo -n "Installing mandatory packages..."
	apt-get -y install curl neovim git btop tree tmux net-tools jq
	echo " done."

	# add mount point for NAS
	if ! grep -q -F '/mnt/nas' /etc/fstab; then
		echo -n "Adding mount point for NAS..."
		mkdir -p /mnt/nas
		echo "nas.internal.hypr.sh:/ /mnt/nas nfs4 _netdev,auto 0 0" >> /etc/fstab
		mount /mnt/nas &>/dev/null
		systemctl daemon-reload
		echo " done."
	fi


	# create hey user
	if ! id hey &>/dev/null; then
		echo -n "Creating ${USER_NAME} user with password '${USER_PASSWORD}' ..."
		useradd -m -s /bin/bash "${USER_NAME}"
		echo "${USER_NAME}:$USER_PASSWORD}" | chpasswd
		echo "${USER_NAME} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/"${USER_NAME}"
		chmod 0440 /etc/sudoers.d/"${USER_NAME}"
		mkdir -p /home/"${USER_NAME}"/.ssh
		cp /etc/pve/priv/authorized_keys /home/"${USER_NAME}"/.ssh/authorized_keys
		chown -R "${USER_NAME}":"${USER_NAME}" /home/"${USER_NAME}"/.ssh
		# create user on pveam and add the rights to do everythinga
		pveum user add "${USER_NAME}"@pam &>/dev/null
		pveum aclmod / -user "${USER_NAME}"@pam -role Administrator &>/dev/null
		echo " done."
	fi

	echo ""
	echo "All done. Reboot the system to apply changes."
}

gpu() {
	# install dependencies
	apt update -y
	apt install -y git vim "pve-headers-$(uname -r)" mokutil dkms build-* sysfsutils unzip

	# cleanup
	rm -rf /var/lib/dkms/i915-sriov-dkms*
	rm -rf /usr/src/i915-sriov-dkms*
	rm -rf /tmp/i915-sriov-dkms

	# get & prepare i915 dkms
	git clone https://github.com/strongtz/i915-sriov-dkms.git /tmp/i915-sriov-dkms
	cp -a /tmp/i915-sriov-dkms/dkms.conf{,.bak}
	KERNEL=$(uname -r); KERNEL=${KERNEL%-pve}
	sed -i 's/"@_PKGBASE@"/"i915-sriov-dkms"/g' /tmp/i915-sriov-dkms/dkms.conf
	sed -i 's/"@PKGVER@"/"'"$KERNEL"'"/g' /tmp/i915-sriov-dkms/dkms.conf
	sed -i 's/ -j$(nproc)//g' /tmp/i915-sriov-dkms/dkms.conf
	#cat /tmp/i915-sriov-dkms/dkms.conf

	# install i915 dkms
	dkms add /tmp/i915-sriov-dkms
	dkms install -m i915-sriov-dkms -v "$KERNEL" -k "$(uname -r)" --force -j 1
	dkms status

	# enable iommu and i915
	cp -a /etc/kernel/cmdline{,.bak}
	sed -i 's/boot=zfs/boot=zfs intel_iommu=on iommu=pt i915.enable_guc=3 i915.max_vfs=7/g' /etc/kernel/cmdline
	proxmox-boot-tool refresh
	echo "devices/pci0000:00/0000:00:02.0/sriov_numvfs = 7" > /etc/sysfs.d/i915-sriov.conf

	echo "Reboot to apply changes, afterwards run the following commands to verfiy the installation:"
	echo "lspci | grep VGA to check if i915 is loaded with 7 VFs"
	echo "dmesg | grep i915 to check if i915 is loaded with GuC firmware"
}

resgroup() {
    pvesh create /cluster/mapping/pci --id igpu \
        --map node=pve1,path=0000:00:02.1,iommugroup=16,id=8086:46a6,subsystem-id=8086:3024 \
        --map node=pve1,path=0000:00:02.2,iommugroup=17,id=8086:46a6,subsystem-id=8086:3024 \
        --map node=pve1,path=0000:00:02.3,iommugroup=18,id=8086:46a6,subsystem-id=8086:3024 \
        --map node=pve1,path=0000:00:02.4,iommugroup=19,id=8086:46a6,subsystem-id=8086:3024 \
        --map node=pve1,path=0000:00:02.5,iommugroup=20,id=8086:46a6,subsystem-id=8086:3024 \
        --map node=pve1,path=0000:00:02.6,iommugroup=21,id=8086:46a6,subsystem-id=8086:3024 \
        --map node=pve1,path=0000:00:02.7,iommugroup=22,id=8086:46a6,subsystem-id=8086:3024 \
        --map node=pve2,path=0000:00:02.1,iommugroup=16,id=8086:46a6,subsystem-id=8086:3024 \
        --map node=pve2,path=0000:00:02.2,iommugroup=17,id=8086:46a6,subsystem-id=8086:3024 \
        --map node=pve2,path=0000:00:02.3,iommugroup=18,id=8086:46a6,subsystem-id=8086:3024 \
        --map node=pve2,path=0000:00:02.4,iommugroup=19,id=8086:46a6,subsystem-id=8086:3024 \
        --map node=pve2,path=0000:00:02.5,iommugroup=20,id=8086:46a6,subsystem-id=8086:3024 \
        --map node=pve2,path=0000:00:02.6,iommugroup=21,id=8086:46a6,subsystem-id=8086:3024 \
        --map node=pve2,path=0000:00:02.7,iommugroup=22,id=8086:46a6,subsystem-id=8086:3024 \
        --map node=pve3,path=0000:00:02.1,iommugroup=16,id=8086:46a6,subsystem-id=8086:3024 \
        --map node=pve3,path=0000:00:02.2,iommugroup=17,id=8086:46a6,subsystem-id=8086:3024 \
        --map node=pve3,path=0000:00:02.3,iommugroup=18,id=8086:46a6,subsystem-id=8086:3024 \
        --map node=pve3,path=0000:00:02.4,iommugroup=19,id=8086:46a6,subsystem-id=8086:3024 \
        --map node=pve3,path=0000:00:02.5,iommugroup=20,id=8086:46a6,subsystem-id=8086:3024 \
        --map node=pve3,path=0000:00:02.6,iommugroup=21,id=8086:46a6,subsystem-id=8086:3024 \
        --map node=pve3,path=0000:00:02.7,iommugroup=22,id=8086:46a6,subsystem-id=8086:3024
}

check_ssh_key() {
	if ! ssh -o BatchMode=yes -o ConnectTimeout=5 root@"${HOST}" 'exit'; then
		ssh-copy-id -i "${SSHKEY_PATH}" root@"${HOST}"
	fi
}

copy_script() {
	scp "$0" root@"${HOST}":/usr/local/bin/init-pve 1>/dev/null
}

run() {
	if ! command -v pveversion &>/dev/null; then
		check_ssh_key
		copy_script
		ssh -qt root@"${HOST}" -- init-pve "${@:2}"
	else
		$ACTION "$@"
	fi
}

ping() {
	ssh -qt root@"${HOST}" echo "pong from \${HOSTNAME}, \$(pveversion)"
}

usage() {
    echo "Usage: $0 <action> [host] [user] [password] [sshkey]"
    echo "Actions:"
    echo "  ping: ping the host"
    echo "  setup: setup the host"
    echo "  gpu: setup gpu passthrough"
    echo "  resgroup: setup resgroup for igpu"
    exit 1
}

case ${ACTION} in
	ping) ping ;;
	setup) run setup "$@" ;;
	gpu) run gpu "$@" ;;
	resgroup) run resgroup "$@" ;;
	*) usage ;;
esac
