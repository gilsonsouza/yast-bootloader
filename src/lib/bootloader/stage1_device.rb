require "yast"
require "y2storage"
require "bootloader/udev_mapping"

Yast.import "BootStorage"

module Bootloader
  # Purpose of this class is provide mapping between intentioned stage1 location
  # and real one as many virtual devices cannot be used for stage1 like md
  # devices or lvm
  #
  # @example
  #   # system with lvm, /boot lives on /dev/system/root. /dev/system is
  #   # created from /dev/sda1 and /dev/sdb1
  #   dev = Stage1Device.new("/dev/system/boot")
  #   puts dev.real_devices # => ["/dev/sda1", "/dev/sdb1"]
  class Stage1Device
    include Yast::Logger

    # @param [String] device intended location of stage1. Device here
    #   means any name  under /dev like "/dev/sda", "/dev/system/root" or
    #   "/dev/md-15". Such device have to be in kernel name, so no udev links.
    def initialize(device)
      @intended_device = device
    end

    # @return [Array<String>] list of devices where stage1 need to be installed
    # to fit the best intended device. Devices used kernel device names, so no
    # udev names
    def real_devices
      return @real_devices if @real_devices

      @real_devices = underlaying_devices_for(@intended_device)

      log.info "Stage1 real devices for #{@intended_device} is #{@real_devices}"

      @real_devices
    end

  private

    def devicegraph
      Y2Storage::StorageManager.instance.staging
    end

    # underlaying_devices without any caching
    # @see #underlaying_devices
    def underlaying_devices_for(dev)
      dev = UdevMapping.to_kernel_device(dev)
      res = underlaying_devices_one_level(dev)

      # some underlaying devices added, so run recursive to ensure that it is really bottom one
      res = res.each_with_object([]) { |d, f| f.concat(underlaying_devices_for(d)) }

      # TODO: check if res empty is caused by filtering out lvm on partitionless disk
      res = [dev] if res.empty?

      res.uniq
    end

    def pv_disk(vg)
      pvs = usable_pvs(vg)
      pvs.map { |p| p.ancestors.find { |a| a.is?(:disk) }.name }
    end

    # get one level of underlaying devices, so no recursion deeper
    def underlaying_devices_one_level(dev)
      # FIXME: there is nothing like this right now in libstorage-ng
      #  a_vg.name #=> "/dev/vgname"
      # revisit when such thing exist
      match = /^\/dev\/(\w+)$/.match(dev)
      if match && match[1]
        vg = devicegraph.lvm_vgs.find { |v| v.vg_name == match[1] }
        return pv_disk(vg) if vg
      end

      lvs = devicegraph.lvm_lvs.find { |v| v.name == dev }
      return usable_pvs(lvs.lvm_vg).map { |v| v.blk_device.name } if lvs && lvs.lvm_vg

      # TODO: storage-ng
      # md
      # md disk is just virtual device, so select underlaying device /boot partition
      # return underlaying_disk_with_boot_partition

      # TODO: storage-ng
      # DMRAID main device - not implemented in libstorage-ng
      # return disk["devices"]

      # TODO: storage-ng
      # DMRAID part device - not implemented in libstorage-ng
      # return mapper["devices"]
      #
      # TODO: storage-ng
      # sw_raid
      # return devices_on(part)

      []
    end

    # Physical volumes from a given set of volume groups that are useful for the
    # bootloader.
    #
    # Ignores physical volumes on a whole disk. See bnc#980529
    #
    # @param volume_group [Y2Storage::LvmVg]
    # @return [Array<Y2Storage::LvmPv>]
    def usable_pvs(volume_group)
      volume_group.lvm_pvs.reject { |pv| pv.plain_blk_device.is?(:disk) }
    end

    # For pure virtual disk devices it is selected /boot partition and its
    # underlaying devices then for it select on which disks it lives. So result
    # is disk which contain partition holding /boot.
    def underlaying_disk_with_boot_partition
      underlaying_devices_for(Yast::BootStorage.boot_partition.name).map do |part|
        disk_dev = Yast::Storage.GetDiskPartition(part)
        disk_dev["disk"]
      end
    end

    # returns devices which constructed passed device.
    # @param [Hash] dev is part of target map with given device
    def devices_on(dev)
      (dev["devices"] || []) + (dev["devices_add"] || [])
    end
  end
end
