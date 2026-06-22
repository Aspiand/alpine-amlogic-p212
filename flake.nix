{
  description = "Alpine Linux SD card image for Amlogic P212 (S905X)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
  let
    system = "x86_64-linux";
    pkgs = import nixpkgs { inherit system; };
    lib = pkgs.lib;

    # Cross-compilation: build on x86_64, target aarch64
    crossPkgs = import nixpkgs {
      inherit system;
      crossSystem = {
        config = "aarch64-unknown-linux-gnu";
      };
    };
    bPkgs = crossPkgs.buildPackages; # host tools

    # ---------------------------------------------------------------------------
    # 1. Kernel — cross-compiled aarch64 + Armbian config
    # ---------------------------------------------------------------------------
    kernel = crossPkgs.stdenv.mkDerivation {
      pname = "linux";
      version = "6.18.35";

      src = bPkgs.fetchurl {
        url = "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.18.35.tar.xz";
        hash = "sha256-94YCkyIZEl4hHF9b/YTtz9TsXOiPyUT4JIQT9mW+8jY=";
      };

      nativeBuildInputs = with bPkgs; [
        stdenv.cc bc bison flex dtc openssl perl python3 kmod elfutils gawk
      ];

      configurePhase = ''
        cp ${bPkgs.fetchurl {
          name = "linux-meson64-current.config";
          url = "https://raw.githubusercontent.com/armbian/build/main/config/kernel/linux-meson64-current.config";
          hash = "sha256-OTIofurbfpQGh2ppsiApH/qh2ZUXhN4Ew8KM12TEj2s=";
        }} .config
        make ARCH=arm64 CROSS_COMPILE=${crossPkgs.stdenv.cc.targetPrefix} olddefconfig
      '';

      buildPhase = ''
        export C_INCLUDE_PATH="${bPkgs.openssl.dev}/include"
        export CPLUS_INCLUDE_PATH="${bPkgs.openssl.dev}/include"
        export LIBRARY_PATH="${bPkgs.openssl.out}/lib"
        make ARCH=arm64 CROSS_COMPILE=${crossPkgs.stdenv.cc.targetPrefix} \
          -j$NIX_BUILD_CORES Image modules dtbs
      '';

      installPhase = ''
        mkdir -p $out

        # Kernel image
        cp arch/arm64/boot/Image $out/

        # Modules
        make ARCH=arm64 CROSS_COMPILE=${crossPkgs.stdenv.cc.targetPrefix} \
          modules_install INSTALL_MOD_PATH=$out

        # depmod
        KVER=$(make ARCH=arm64 -s kernelrelease)
        depmod -a -b $out "$KVER"

        # DTB
        mkdir -p $out/dtbs/amlogic
        cp arch/arm64/boot/dts/amlogic/meson-gxl-s905x-p212.dtb $out/dtbs/amlogic/
      '';

      meta.platforms = [ "aarch64-linux" ];
    };

    # ---------------------------------------------------------------------------
    # 2. U-Boot — cross-compiled with custom .config
    # ---------------------------------------------------------------------------
    uboot = crossPkgs.stdenv.mkDerivation {
      pname = "u-boot";
      version = "2026.01";

      src = bPkgs.fetchurl {
        url = "https://ftp.denx.de/pub/u-boot/u-boot-2026.01.tar.bz2";
        hash = "sha256-tg1YZc79vHXajaQVbFbEWOAN51pJuAwaLlipbjCtDVQ=";
      };

      nativeBuildInputs = with bPkgs; [
        stdenv.cc bc bison flex dtc python3 openssl.out openssl.dev
        gnutls swig python3Packages.setuptools
      ];

      configurePhase = ''
        cp ${./bootloader/u-boot/.config} .config
        export C_INCLUDE_PATH="${bPkgs.openssl.dev}/include"
        export CPLUS_INCLUDE_PATH="${bPkgs.openssl.dev}/include"
        export LIBRARY_PATH="${bPkgs.openssl.out}/lib"
        make ARCH=arm CROSS_COMPILE=${crossPkgs.stdenv.cc.targetPrefix} olddefconfig
      '';

      buildPhase = ''
        export C_INCLUDE_PATH="${bPkgs.gnutls.dev}/include:${bPkgs.openssl.dev}/include"
        export CPLUS_INCLUDE_PATH="${bPkgs.gnutls.dev}/include:${bPkgs.openssl.dev}/include"
        export LIBRARY_PATH="${bPkgs.openssl.out}/lib:${bPkgs.gnutls.out}/lib"
        make ARCH=arm CROSS_COMPILE=${crossPkgs.stdenv.cc.targetPrefix} \
          -j$NIX_BUILD_CORES
      '';

      installPhase = ''
        mkdir -p $out
        cp u-boot.bin $out/
      '';

      meta.platforms = [ "aarch64-linux" ];
    };

    # ---------------------------------------------------------------------------
    # 3. Uboot scripts — aml_autoscript + s905_autoscript
    # ---------------------------------------------------------------------------
    ubootScripts = bPkgs.stdenv.mkDerivation {
      pname = "uboot-scripts";
      version = "1.0";
      dontUnpack = true;
      nativeBuildInputs = with bPkgs; [ ubootTools ];

      installPhase = ''
        mkdir -p $out
        ${bPkgs.ubootTools}/bin/mkimage -A arm64 -T script -C none \
          -d ${./bootloader/aml_autoscript.cmd} $out/aml_autoscript
        ${bPkgs.ubootTools}/bin/mkimage -A arm64 -T script -C none \
          -d ${./bootloader/s905_autoscript.cmd} $out/s905_autoscript
      '';
    };

    # ---------------------------------------------------------------------------
    # 4. Initramfs — custom init + busybox + e2fsprogs
    # ---------------------------------------------------------------------------
    initramfs = crossPkgs.stdenv.mkDerivation {
      pname = "initramfs";
      version = "1.0";
      dontUnpack = true;
      nativeBuildInputs = with bPkgs; [ ubootTools ];

      installPhase = ''
        mkdir -p stage/bin stage/sbin stage/dev stage/proc stage/sys stage/newroot

        # Busybox (aarch64) — just the binary, applets installed at runtime
        cp -s ${crossPkgs.busybox}/bin/busybox stage/bin/

        # Tool chainlinks that init script needs
        for app in sh mount umount sleep grep sed basename expr cat echo printf \
                   mkdir reboot sync modprobe tr cut; do
          ln -s /bin/busybox "stage/bin/$app"
        done
        for app in switch_root; do
          ln -s /bin/busybox "stage/sbin/$app"
        done

        # e2fsprogs — for partition expansion (e2fsck, resize2fs)
        cp ${crossPkgs.e2fsprogs}/sbin/e2fsck stage/sbin/
        cp ${crossPkgs.e2fsprogs}/sbin/resize2fs stage/sbin/
        cp ${crossPkgs.util-linux}/sbin/fdisk stage/sbin/

        # Init script
        cp ${./initramfs/init} stage/init
        chmod +x stage/init

        # Minimal device nodes
        mknod -m 600 stage/dev/console c 5 1
        mknod -m 666 stage/dev/null c 1 3

        # Kernel modules required at boot (loop, squashfs, simpledrm)
        # These are extracted from kernel build
        KERNEL=${kernel}
        mkdir -p stage/lib/modules
        for mod in loop squashfs simpledrm; do
          find "$KERNEL/lib/modules" -name "$mod.ko*" -exec cp -v {} stage/lib/modules/ \; 2>/dev/null || true
        done

        # Create cpio + compress
        cd stage
        find . -print0 | cpio --null -H newc -o | gzip > $out/initramfs.cpio.gz

        # U-Boot wrapped ramdisk
        mkimage -A arm64 -T ramdisk -C gzip \
          -d $out/initramfs.cpio.gz $out/uInitrd
      '';

      meta.platforms = [ "aarch64-linux" ];
    };

    # ---------------------------------------------------------------------------
    # 5. Rootfs — Alpine packages via apk + overlay config
    # ---------------------------------------------------------------------------
    rootfs = crossPkgs.stdenv.mkDerivation {
      pname = "alpine-rootfs";
      version = "3.23.2";
      dontUnpack = true;

      nativeBuildInputs = with bPkgs; [ apk-tools cacert ];

      # Fixed-output derivation — needs network for apk
      outputHashMode = "recursive";
      outputHashAlgo = "sha256";
      outputHash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";

      buildPhase = ''
        mkdir -p $out

        # CA cert bundle for TLS
        export SSL_CERT_FILE="${bPkgs.cacert}/etc/ssl/certs/ca-bundle.crt"

        # Build Alpine rootfs for aarch64
        apk --arch aarch64 --root $out --initdb --usermode add \
          --allow-untrusted --no-scripts \
          --repository https://dl-cdn.alpinelinux.org/alpine/v3.23/main \
          --repository https://dl-cdn.alpinelinux.org/alpine/v3.23/community \
          $(cat ${./rootfs/etc/apk/world})
      '';

      installPhase = ''
        # Apply overlay config from repo
        cp -r ${./rootfs/etc} $out/etc/

        # Set root password: "1234" (openssl passwd -6 1234)
        HASH=$(openssl passwd -6 "1234")
        sed -i "s|^root:[^:]*:|root:$HASH:|" $out/etc/shadow

        # Remove apk cache
        rm -rf $out/etc/apk/cache
        rm -rf $out/var/cache/apk
      '';
    };

    # ---------------------------------------------------------------------------
    # 6. SD Card Image
    # ---------------------------------------------------------------------------
    sdImage = pkgs.stdenv.mkDerivation {
      pname = "alpine-amlogic-p212-sdimage";
      version = "2026.0115";
      dontUnpack = true;

      nativeBuildInputs = with pkgs; [
        dosfstools e2fsprogs mtools parted util-linux gzip
      ];

      installPhase = ''
        mkdir -p $out

        # Image file
        IMG="$out/alpine-p212-2026.0115.img"
        truncate -s 2G "$IMG"

        # MBR partition table
        sfdisk "$IMG" << PART_EOF
label: dos
unit: MiB
start=1 size=511 type=c bootable
start=512 type=83
PART_EOF

        # Partition 1: BOOT (FAT32)
        BOOT_OFFSET=$((1*1024*1024))
        BOOT_SIZE=$((511*1024*1024))
        truncate -s $BOOT_SIZE $out/boot.part
        mkfs.vfat -F 32 -n BOOT $out/boot.part

        # Populate BOOT partition
        export MTOOLS_NO_VFAT=1
        mcopy -i $out/boot.part ${kernel}/Image ::/Image
        mcopy -i $out/boot.part ${initramfs}/uInitrd ::/uInitrd
        mmd -i $out/boot.part ::/dtbs
        mmd -i $out/boot.part ::/dtbs/amlogic
        mcopy -i $out/boot.part ${kernel}/dtbs/amlogic/meson-gxl-s905x-p212.dtb ::/dtbs/amlogic/
        mcopy -i $out/boot.part ${uboot}/u-boot.bin ::/u-boot.bin
        mcopy -i $out/boot.part ${ubootScripts}/aml_autoscript ::/aml_autoscript
        mcopy -i $out/boot.part ${ubootScripts}/s905_autoscript ::/s905_autoscript
        mmd -i $out/boot.part ::/extlinux
        mcopy -i $out/boot.part ${./bootloader/extlinux/extlinux.conf} ::/extlinux/extlinux.conf

        # Partition 2: ROOTFS (EXT4)
        ROOTFS_SIZE=$((2048-512-1)) # MiB, minus MBR+overhead
        dd if=/dev/zero of=$out/root.part bs=1M count=$ROOTFS_SIZE
        mkfs.ext4 -F -L ROOTFS -O ^metadata_csum -d ${rootfs} $out/root.part

        # Assemble: write partitions into image at offsets
        dd if=$out/boot.part of="$IMG" seek=$BOOT_OFFSET bs=1 conv=notrunc status=none
        ROOT_OFFSET=$((512*1024*1024))
        dd if=$out/root.part of="$IMG" seek=$ROOT_OFFSET bs=1 conv=notrunc status=none

        # Compress
        gzip -9fk "$IMG"
      '';

      meta.platforms = [ "x86_64-linux" ];
    };

  in {
    packages.${system} = {
      inherit kernel uboot ubootScripts initramfs rootfs;
      default = sdImage;
    };
  };
}
