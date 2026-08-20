ARG OTP_VERSION=29.0.5
ARG ELIXIR_VERSION=1.20.3
ARG ELIXIR_IMAGE=ghcr.io/groguelon/lambda-layer-erlang:${OTP_VERSION}

FROM ${ELIXIR_IMAGE} AS build-elixir

RUN sed -i 's/^keepcache=.*/keepcache=1/' /etc/dnf/dnf.conf || \
    echo 'keepcache=1' >> /etc/dnf/dnf.conf

RUN --mount=type=cache,target=/var/cache/dnf,sharing=locked \
    dnf -y upgrade && \
    dnf -y --setopt=install_weak_deps=0 --nodocs install \
        ca-certificates \
        ncurses-libs \
        unixODBC \
        make \
        unzip \
        wget

ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

ARG OTP_VERSION
ARG ELIXIR_VERSION

RUN ERLANG_MAJOR="${OTP_VERSION%%.*}" \
    && ELIXIR_SHA256=$(wget -q -O - "https://builds.hex.pm/builds/elixir/builds.txt" | awk -v v="v${ELIXIR_VERSION}-otp-${ERLANG_MAJOR}" '$1 == v {print $4}') \
    && test -n "${ELIXIR_SHA256}" \
    && wget -q -O elixir.zip "https://repo.hex.pm/builds/elixir/v${ELIXIR_VERSION}-otp-${ERLANG_MAJOR}.zip" \
    && echo "${ELIXIR_SHA256}  elixir.zip" | sha256sum -c - \
    && unzip -d /ELIXIR elixir.zip \
    && rm elixir.zip

WORKDIR /ELIXIR

RUN make -o compile DESTDIR=/ELIXIR_LOCAL install

ENV MIX_HOME=/ELIXIR_LOCAL/usr/local/lib/elixir/.mix \
    HEX_HOME=/ELIXIR_LOCAL/usr/local/lib/elixir/.hex \
    PATH=/ELIXIR_LOCAL/usr/local/bin:$PATH

RUN mix do local.hex --force + local.rebar --force

## Final

FROM ${ELIXIR_IMAGE} AS final

LABEL org.opencontainers.image.source=https://github.com/GRoguelon/aws_lambda_runtime
LABEL org.opencontainers.image.description="Elixir toolchain on top of the lambda-layer-erlang image, used as the build environment for mix aws_lambda.build to compile and package AWS Lambda functions"

ENV MIX_HOME=/usr/local/lib/elixir/.mix \
    HEX_HOME=/usr/local/lib/elixir/.hex

RUN dnf -y upgrade && \
    dnf -y --setopt=install_weak_deps=0 --nodocs install \
        git \
        tar \
        zip

COPY --link --from=build-elixir /ELIXIR_LOCAL/usr/local /usr/local
