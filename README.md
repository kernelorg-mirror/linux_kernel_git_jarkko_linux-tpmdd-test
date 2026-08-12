# linux-tpmdd test suite

## Building

### Host

```sh
make build BOARD=tpmdd_amd64
make build BOARD=tpmdd_arm64
```

The ARM64 build produces one `tpmdd_arm64.img` for QEMU, Raspberry Pi 3,
and Raspberry Pi 4/400.

### OCI container

```sh
CONTAINER=docker ./scripts/build.sh
```

Builds every board defconfig; Buildroot downloads/ccache stay in `tpmdd-cache`.

## Running

```sh
make qemu BOARD=tpmdd_amd64
make qemu BOARD=tpmdd_arm64
```

Flash images with `make burn` (requires `DEVICE`):

```sh
make burn BOARD=tpmdd_amd64 DEVICE=/dev/sdX
make burn BOARD=tpmdd_arm64 DEVICE=/dev/sdX
```

The generated SSH client configuration is located at
`build/<BOARD>/images/ssh_config`.

Open a root SSH session with the generated client configuration:

```sh
make ssh BOARD=tpmdd_amd64
```

