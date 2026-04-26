# linux-tpmdd test suite

## Building

1.  **Configure the project** (only needed for the first build):
    ```
    just prepare configs/pc_x86_64_efi_defconfig
    ```

2.  **Build the image**:
    ```
    just all
    ```
    For any subsequent changes, you can simply re-run `just all`.
