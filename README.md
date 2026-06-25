# linux-tpmdd test suite

## Building

1.  **Configure the project** (only needed for the first build):
    ```
    make configure BOARD=tpmdd_amd64_efi
    ```

2.  **Build the image**:
    ```
    make build BOARD=tpmdd_amd64_efi
    ```
    For any subsequent changes, you can simply re-run `make build BOARD=tpmdd_amd64_efi`.
