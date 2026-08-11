# ============================================================================
# Build environment for cross-compiling Samba 4 for the Infrant SPARC ReadyNAS.
# Debian bullseye x86-64. Everything the build needs lives in this image, so
# the host (macOS included) only needs Docker.
#
#   docker build -t readynas-samba4 .
#   docker run --rm -it -v "$PWD":/work readynas-samba4 ./build.sh all
# ============================================================================
FROM debian:bullseye

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
      # --- crosstool-NG build prerequisites ---
      build-essential gcc g++ make \
      bison flex texinfo gawk help2man \
      libtool-bin libtool automake autoconf \
      gperf ncurses-dev unzip \
      libncurses5-dev bzip2 xz-utils \
      # --- fetching / patching sources ---
      wget curl ca-certificates git rsync patch file \
      # --- Samba host-side build tooling (waf runs on the host) ---
      # libparse-yapp-perl provides Parse::Yapp::Driver, required by Samba's
      # IDL compiler (pidl) even for a file-server-only build.
      python3 python3-dev perl libparse-yapp-perl pkg-config \
      # --- qemu user-mode: provides qemu-sparc-static for waf cross-execute ---
      qemu-user-static \
      # --- setpriv (drop privileges in the entrypoint) ---
      util-linux \
    && rm -rf /var/lib/apt/lists/*

# The container starts as root; the entrypoint synthesizes a passwd entry for
# the caller's host UID and drops to it before building. crosstool-NG won't run
# as root, and tools like `id -un` need a real passwd entry — the entrypoint
# satisfies both. See entrypoint.sh for the full rationale.
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

WORKDIR /work
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["bash"]
