ARG ELIXIR_VERSION=1.20.3
ARG ERLANG_VERSION=28.1.1
ARG ALPINE_VERSION=3.22.5
ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${ERLANG_VERSION}-alpine-${ALPINE_VERSION}"
ARG RUNNER_IMAGE="alpine:${ALPINE_VERSION}"

# ---------------------------------------------------------------------------
# Stage 1: build the release. Nothing from this stage ships except the release
# directory copied out at the bottom of the file.
# ---------------------------------------------------------------------------
FROM ${BUILDER_IMAGE} AS builder

RUN apk add --no-cache build-base git ca-certificates

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV="prod"

# Dependencies are fetched and compiled before any application source is
# copied, so editing an app does not invalidate the dependency layers.
COPY mix.exs mix.lock ./
COPY apps/restdis_buster/mix.exs apps/restdis_buster/
COPY apps/restdis_replicator/mix.exs apps/restdis_replicator/
COPY apps/restdis_repo/mix.exs apps/restdis_repo/
COPY apps/restdis_server/mix.exs apps/restdis_server/
COPY apps/restdis/mix.exs apps/restdis/

RUN mix deps.get --only $MIX_ENV
RUN mix deps.compile

COPY config/config.exs config/${MIX_ENV}.exs config/
COPY apps apps

RUN mix compile

COPY config/runtime.exs config/
COPY rel rel

RUN mix release restdis

# Drop build-time tooling that mix release copies into ERTS but that the
# release never executes, along with header files and NIF object directories.
RUN cd /app/_build/prod/rel/restdis \
  && rm -f erts-*/bin/dialyzer erts-*/bin/typer erts-*/bin/erlc erts-*/bin/ct_run \
  && rm -rf erts-*/include \
  && rm -rf lib/*/include \
  && rm -rf lib/*/priv/obj

# ---------------------------------------------------------------------------
# Stage 2: runtime. Alpine plus the shared libraries ERTS links against.
# ---------------------------------------------------------------------------
FROM ${RUNNER_IMAGE} AS runner

RUN apk add --no-cache libstdc++ ncurses-libs openssl ca-certificates

# musl treats every locale as UTF-8, so no locale package or generation step
# is needed. LANG is still set because the BEAM reads it to pick its I/O
# encoding.
ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    MIX_ENV=prod \
    CACHE_DATA_DIR=/var/lib/restdis/cache

WORKDIR /app

RUN addgroup -S restdis \
  && adduser -S -G restdis -h /home/restdis -s /bin/sh restdis \
  && mkdir -p /var/lib/restdis/cache /home/restdis \
  && chown -R restdis:restdis /app /var/lib/restdis /home/restdis

COPY --from=builder --chown=restdis:restdis /app/_build/prod/rel/restdis ./

USER restdis

EXPOSE 4040 6380

CMD ["/app/bin/server"]
