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
COPY apps/supa_cacher_buster/mix.exs apps/supa_cacher_buster/
COPY apps/supa_cacher_replicator/mix.exs apps/supa_cacher_replicator/
COPY apps/supa_cacher_repo/mix.exs apps/supa_cacher_repo/
COPY apps/supa_cacher_server/mix.exs apps/supa_cacher_server/
COPY restdis restdis

RUN mix deps.get --only $MIX_ENV
RUN mix deps.compile

COPY config/config.exs config/${MIX_ENV}.exs config/
COPY apps apps

RUN mix compile

COPY config/runtime.exs config/
COPY rel rel

RUN mix release supacacher

# Drop build-time tooling that mix release copies into ERTS but that the
# release never executes, along with header files and NIF object directories.
RUN cd /app/_build/prod/rel/supacacher \
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
    CACHE_DATA_DIR=/var/lib/supacacher/cache

WORKDIR /app

RUN addgroup -S supacacher \
  && adduser -S -G supacacher -h /home/supacacher -s /bin/sh supacacher \
  && mkdir -p /var/lib/supacacher/cache /home/supacacher \
  && chown -R supacacher:supacacher /app /var/lib/supacacher /home/supacacher

COPY --from=builder --chown=supacacher:supacacher /app/_build/prod/rel/supacacher ./

USER supacacher

EXPOSE 4040 6380

CMD ["/app/bin/server"]
