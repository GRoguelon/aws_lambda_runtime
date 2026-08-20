# syntax=docker/dockerfile:1

ARG OTP_VERSION=29.0.5
ARG LAMBDA_IMAGE=public.ecr.aws/lambda/provided:al2023

FROM ${LAMBDA_IMAGE} AS build-erlang

RUN sed -i 's/^keepcache=.*/keepcache=1/' /etc/dnf/dnf.conf || \
    echo 'keepcache=1' >> /etc/dnf/dnf.conf

RUN --mount=type=cache,target=/var/cache/dnf,sharing=locked \
    dnf -y upgrade && \
    dnf -y --setopt=install_weak_deps=0 --nodocs install \
        binutils \
        ca-certificates \
        diffutils \
        file \
        findutils \
        gcc \
        gcc-c++ \
        gzip \
        make \
        ncurses-devel \
        openssl-devel \
        perl \
        tar \
        unixODBC-devel \
        zip \
        zlib-devel

ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

ARG OTP_VERSION

WORKDIR /usr/src/otp

RUN curl -fsSL "https://github.com/erlang/otp/releases/download/OTP-${OTP_VERSION}/otp_src_${OTP_VERSION}.tar.gz" \
  | tar -xz --strip-components=1

# --prefix must be the path the layer lands at: OTP is NOT relocatable,
# erl has ROOTDIR baked in as a literal string.
RUN ./configure \
        --prefix=/opt/otp \
        --with-ssl \
        --with-odbc=yes \
        --enable-jit \
        --enable-threads \
        --without-javac \
        --without-jinterface \
        --enable-kernel-poll \
        --without-wx \
        --without-observer \
        --without-debugger \
        --without-et \
        --without-megaco \
        --without-diameter && \
    make -j$(getconf _NPROCESSORS_ONLN) ODBC_CAN_BUILD_DRIVER=true && \
    make -j$(getconf _NPROCESSORS_ONLN) ODBC_CAN_BUILD_DRIVER=true install

## Trim (all paths under the real prefix, /opt/otp)

RUN set -eux; \
    find /opt/otp/lib/erlang \
        \( -type d -a \( -name man -o -name obj -o -name c_src \
                      -o -name emacs -o -name info -o -name examples \) \) \
        -prune -exec rm -rf {} +; \
    find /opt/otp/lib/erlang -type d -name src \
        -exec find {} -type f ! -name '*.hrl' -delete \; ; \
    find /opt/otp/lib/erlang -type d -empty -delete

# Applications a Lambda runtime never uses. Drop any you actually need.
RUN set -eux; \
    cd /opt/otp/lib/erlang/lib; \
    rm -rf dialyzer-* edoc-* erl_docgen-* common_test-* eunit-* reltool-* xmerl-*

# No pax-utils/scanelf in the AL2023 repos, so classify ELFs with file(1) instead.
RUN set -eu; \
    find /opt/otp -type f \( -perm -u+x -o -name '*.so' -o -name '*.so.*' \) -print \
    | while IFS= read -r f; do \
        case "$(file -b "$f")" in \
            *ELF*executable*)     strip --strip-all "$f" 2>/dev/null || true ;; \
            *ELF*shared\ object*) strip --strip-unneeded "$f" 2>/dev/null || true ;; \
        esac; \
    done

## Bundle shared libs the execution environment does not have.
## Lambda already has /opt/lib on LD_LIBRARY_PATH.
## glibc/ld-linux/libgcc_s are deliberately excluded - they come from the runtime.

RUN set -eux; \
    mkdir -p /opt/lib; \
    find /opt/otp -type f \( -perm -u+x -o -name '*.so*' \) -print0 \
    | xargs -0 -r -n1 ldd 2>/dev/null \
    | awk '/=> \//{print $3}' | sort -u \
    | grep -E 'libcrypto|libssl|libodbc|libltdl|libncurses|libtinfo|libatomic|libstdc' \
    | while read -r lib; do cp -Lv "$lib" /opt/lib/; done

FROM ${LAMBDA_IMAGE} AS final

LABEL org.opencontainers.image.source=https://github.com/GRoguelon/aws_lambda_runtime
LABEL org.opencontainers.image.description="Minimal Erlang/OTP runtime for AWS Lambda, built on the provided:al2023 base image; also extracted as an AWS Lambda layer"

ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    PATH="/opt/otp/bin:$PATH"

RUN dnf -y upgrade && \
    dnf -y --setopt=install_weak_deps=0 --nodocs install \
        ca-certificates \
        ncurses-libs \
        unixODBC

# Erlang/OTP runtime (with ODBC driver support)
COPY --link --from=build-erlang /opt/otp /opt/otp
COPY --link --from=build-erlang /opt/lib /opt/lib
