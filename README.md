# linux-tpmdd test suite

## Building

```
git clone https://gitlab.com/jarkkojs/linux-tpmdd-test.git
cd linux-tpmdd-test
cmake -Bbuild -Dbuildroot_defconfig=<config> && make -Cbuild buildroot-prepare
make -Cbuild/buildroot/build
```

## Test Suite

### Running test suite

```
build/buildroot/build/images/run-tests.sh
```

## Instructions

### Starting

* TPM 2.0 FIFO: `build/buildroot/build/images/run-qemu.sh &`
* TPM 2.0 CRB: `build/buildroot/build/images/run-qemu.sh --tpm-crb &`
* TPM 1.2 FIFO: `build/buildroot/build/images/run-qemu.sh --tpm1 &`

### Stopping

```
kill -15 $(cat build/buildroot/build/images/qemu.pid)
```

### Sockets

* Serial: `build/buildroot/build/images/serial.sock`
* Monitor: `build/buildroot/build/images/monitor.sock`

### SSH

```
ssh -F build/buildroot/build/images/ssh_config tpmdd.local
```
