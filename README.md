# linux-tpmdd test suite

## Building

```sh
make build BOARD=tpmdd_amd64
make build BOARD=tpmdd_arm64
```

## Running

```sh
make qemu BOARD=tpmdd_amd64
```

Flash images with `make burn` (requires `DEVICE`):

```sh
make burn BOARD=tpmdd_amd64 DEVICE=/dev/sdX
make burn BOARD=tpmdd_arm64 DEVICE=/dev/sdX
make burn BOARD=tpmdd_arm64 VARIANT=rpi3b DEVICE=/dev/sdX
make burn BOARD=tpmdd_arm64 VARIANT=rpi400 DEVICE=/dev/sdX
```

The generated SSH client configuration is located at
`build/<BOARD>/images/ssh_config`.
