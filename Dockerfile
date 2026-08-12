# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2024-2026 Jarkko Sakkinen <jarkko@kernel.org>

FROM debian:trixie-slim@sha256:3a39a0592364683e6bab97937b72cad5a8fa6dcbbee90edb3bb48c7f8e94f258

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get -o APT::Retries=3 update \
    && apt-get -o APT::Retries=3 install -y --no-install-recommends \
        bash \
        bc \
        binutils \
        build-essential \
        bzip2 \
        ca-certificates \
        cmake \
        coreutils \
        cpio \
        curl \
        debianutils \
        diffutils \
        file \
        findutils \
        gawk \
        git \
        gosu \
        gzip \
        locales \
        make \
        openssh-client \
        passwd \
        patch \
        perl \
        python3 \
        rsync \
        sed \
        tar \
        unzip \
        util-linux \
        wget \
        xz-utils \
        zstd \
    && sed -i 's/^# *\(en_US.UTF-8 UTF-8\)$/\1/' /etc/locale.gen \
    && locale-gen \
    && rm -rf /var/lib/apt/lists/*

ENV HOME=/cache \
    LC_ALL=en_US.UTF-8

COPY --chmod=0755 scripts/build-helper.sh /usr/local/bin/build-helper

WORKDIR /workspace

CMD ["/usr/local/bin/build-helper"]
