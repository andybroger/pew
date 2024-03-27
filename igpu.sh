#!/bin/bash

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
