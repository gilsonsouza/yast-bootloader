require "yast"

require "bootloader/boot_record_backup"
require "bootloader/stage1_device"
require "yast2/execute"
require "y2storage"

Yast.import "Arch"
Yast.import "PackageSystem"

module Bootloader
  # this class place generic MBR wherever it is needed
  # and also mark needed partitions with boot flag and legacy_boot
  # FIXME: make it single responsibility class
  class MBRUpdate
    include Yast::Logger

    # Update contents of MBR (active partition and booting code)
    def run(stage1)
      log.info "Stage1: #{stage1.inspect}"
      @stage1 = stage1

      create_backups

      # Rewrite MBR with generic boot code only if we do not plan to install
      # there bootloader stage1
      install_generic_mbr if stage1.generic_mbr? && !stage1.mbr?

      activate_partitions if stage1.activate?
    end

  private

    def devicegraph
      Y2Storage::StorageManager.instance.staging
    end

    def mbr_disk
      @mbr_disk ||= Yast::BootStorage.mbr_disk.name
    end

    def create_backups
      devices_to_backup = disks_to_rewrite + @stage1.devices + [mbr_disk]
      devices_to_backup.uniq!
      log.info "Creating backup of boot sectors of #{devices_to_backup}"
      backups = devices_to_backup.map do |d|
        ::Bootloader::BootRecordBackup.new(d)
      end
      backups.each(&:write)
    end

    def gpt?(disk)
      mbr_storage_object = devicegraph.disks.find { |d| d.name == disk }
      raise "Cannot find in storage mbr disk #{disk}" unless mbr_storage_object
      mbr_storage_object.gpt?
    end

    GPT_MBR = "/usr/share/syslinux/gptmbr.bin".freeze
    DOS_MBR = "/usr/share/syslinux/mbr.bin".freeze
    def generic_mbr_file_for(disk)
      @generic_mbr_file ||= gpt?(disk) ? GPT_MBR : DOS_MBR
    end

    def install_generic_mbr
      Yast::PackageSystem.Install("syslinux") unless Yast::Stage.initial

      disks_to_rewrite.each do |disk|
        log.info "Copying generic MBR code to #{disk}"
        # added fix 446 -> 440 for Vista booting problem bnc #396444
        command = ["/bin/dd", "bs=440", "count=1", "if=#{generic_mbr_file_for(disk)}", "of=#{disk}"]
        Yast::Execute.locally(*command)
      end
    end

    def set_parted_flag(disk, part_num, flag)
      # we need at first clear this flag to avoid multiple flags (bnc#848609)
      reset_flag(disk, flag)

      # and then set it
      command = ["/usr/sbin/parted", "-s", disk, "set", part_num, flag, "on"]
      Yast::Execute.locally(*command)
    end

    def reset_flag(disk, flag)
      command = ["/usr/sbin/parted", "-sm", disk, "print"]
      out = Yast::Execute.locally(*command, stdout: :capture)

      partitions = out.lines.select do |line|
        values = line.split(":")
        values[6] && values[6].match(/(?:\s|\A)#{flag}/)
      end
      partitions.map! { |line| line.split(":").first }

      partitions.each do |part_num|
        command = ["/usr/sbin/parted", "-s", disk, "set", part_num, flag, "off"]
        Yast::Execute.locally(*command)
      end
    end

    def can_activate_partition?(disk, partition)
      # if primary partition on old DOS MBR table, GPT do not have such limit

      !(Yast::Arch.ppc && disk.gpt?) && !partition.is?(:logical)
    end

    def activate_partitions
      partitions_to_activate.each do |partition|
        num = partition.number
        disk = partition.partitionable
        if num.nil? || disk.nil?
          raise "INTERNAL ERROR: Data for partition to activate is invalid."
        end

        next unless can_activate_partition?(disk, partition)

        log.info "Activating partition #{partition.inspect}"
        # set corresponding flag only bnc#930903
        if disk.gpt?
          # for legacy_boot storage_ng do not reset others, so lets
          # do it manually
          set_parted_flag(disk.name, num, "legacy_boot")
        else
          set_parted_flag(disk.name, num, "boot")
        end
      end
    end

    def boot_devices
      @stage1.devices
    end

    # Get the list of MBR disks that should be rewritten by generic code
    # if user wants to do so
    # @return a list of device names to be rewritten
    def disks_to_rewrite
      # find the MBRs on the same disks as the devices underlying the boot
      # devices; if for any of the "underlying" or "base" devices no device
      # for acessing the MBR can be determined, include mbr_disk in the list
      mbrs = boot_devices.map do |dev|
        partition_to_activate(dev).partitionable.name || mbr_disk
      end
      ret = [mbr_disk]
      # Add to disks only if part of raid on base devices lives on mbr_disk
      ret.concat(mbrs) if mbrs.include?(mbr_disk)
      # get only real disks
      ret = ret.each_with_object([]) do |disk, res|
        res.concat(::Bootloader::Stage1Device.new(disk).real_devices)
      end

      ret.uniq
    end

    def first_base_device_to_boot(md_device)
      md = ::Bootloader::Stage1Device.new(md_device)
      # storage-ng
      # No BIOS-ID support in libstorage-ng, so just return first one
      md.real_devices.first
# rubocop:disable Style/BlockComments
=begin
      md.real_devices.min_by { |device| bios_id_for(device) }
=end
      # rubocop:enable all
    end

    MAX_BIOS_ID = 1000
    def bios_id_for(device)
      disk = Yast::Storage.GetDiskPartition(device)["disk"]
      disk_info = target_map[disk]
      return MAX_BIOS_ID unless disk_info

      bios_id = disk_info["bios_id"]
      # prefer device without bios id over ones without disk info
      return MAX_BIOS_ID - 1  if !bios_id || bios_id !~ /0x[0-9a-fA-F]+/

      bios_id[2..-1].to_i(16) - 0x80
    end

    # List of partition for disk that can be used for setting boot flag
    def activatable_partitions(disk)
      return [] unless disk

      # do not select swap and do not select BIOS grub partition
      # as it clear its special flags (bnc#894040)
      disk.partitions.reject { |p| p.id.is?(:swap, :bios_boot) }
    end

    def extended_partition(partition)
      part = partition.partitionable.partitions.find { |p| p.type.is?(:extended) }
      return nil unless part

      log.info "Using extended partition instead: #{part.inspect}"
      part
    end

    # Given a device name (the bootloader location), returns the partition
    # to activate.
    #
    # Raises an exception if no suitable partition to activate was found.
    #
    # @param loader_device [String] the device to install the bootloader to
    #
    # @return [Y2Storage::Partition]
    #
    def partition_to_activate(loader_device)
      # storage-ng
      # FIXME
      # going through 'real' device(s) here is almost certainly wrong; atm the
      # unfinished storage-ng adjustments make this a no-op and it works
      real_device = first_base_device_to_boot(loader_device)
      log.info "real device for #{loader_device.inspect} is #{real_device.inspect}"
      partition = to_partition(real_device)

      raise "Invalid loader device #{loader_device.inspect}" unless partition

      if partition.type == Storage::PartitionType_LOGICAL
        log.info "Bootloader partition cannot be a logical partition, using extended"
        partition = extended_partition(partition)
      end

      log.info "Partition for activating: #{partition.inspect}"
      partition
    end

    # Given a device name it returns the device if it's a partition or the
    # first partition (if one exists) on this device.
    #
    # Returns nil otherwise.
    #
    # @param dev_name [String] device name
    #
    # @return [Y2Storage::Partition, nil]
    #
    def to_partition(dev_name)
      partition = Y2Storage::Partition.find_by_name(devicegraph, dev_name)
      return partition if partition

      device = Y2Storage::Partitionable.find_by_name(devicegraph, dev_name)
      return nil unless device

      # (bnc # 337742) - Unable to boot the openSUSE (32 and 64 bits) after installation
      # if loader_device is disk Choose any partition which is not swap to
      # satisfy such bios (bnc#893449)
      partition = activatable_partitions(device).first
      log.info "loader_device is disk device, so use its partition #{partition.inspect}"

      partition
    end

    # Get a list of partitions to activate if user wants to activate
    # boot partition
    # @return a list of partitions to activate
    def partitions_to_activate
      result = boot_devices

      result.map! { |partition| partition_to_activate(partition) }

      result.compact.uniq
    end
  end
end
