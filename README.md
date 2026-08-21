# linux-tpmdd test suite

bootc container host for linux-tpmdd kernel testing. Builds a live ISO/image
and an OCI bootc image (`rootfs-oci-latest-<arch>-linux.oci-image.tar`).

## Building

### Host

```sh
make build BOARD=tpmdd_amd64
make build BOARD=tpmdd_arm64
```

Artifacts under `build/<BOARD>/images/`:

- `tpmdd_amd64.iso` / `tpmdd_arm64.img` — live test media
- `rootfs-oci-latest-<arch>-linux.oci-image.tar` — OCI bootc container (`containers.bootc=1`)
- `image.manifest` — imgref/digest metadata
- `ssh_config` — generated SSH client config

### OCI container

```sh
CONTAINER=docker ./scripts/build.sh
```

Builds every board defconfig; Buildroot downloads/ccache stay in `tpmdd-cache`.

## Running

Flash images with `make burn` (requires `DEVICE`):

```sh
make burn BOARD=tpmdd_amd64 DEVICE=/dev/sdX
make burn BOARD=tpmdd_arm64 DEVICE=/dev/sdX
```

Open a root SSH session with the generated client configuration:

```sh
make ssh BOARD=tpmdd_amd64
```
