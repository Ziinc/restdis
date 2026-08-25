ARG ELIXIR_VERSION=1.20.3
ARG ERLANG_VERSION=28.1.1
ARG DEBIAN_VERSION=trixie-20260803
ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${ERLANG_VERSION}-debian-${DEBIAN_VERSION}-slim"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}-slim"

FROM ${BUILDER_IMAGE} AS builder

RUN apt-get update -y \
  && apt-get install -y --no-install-recommends build-essential git ca-certificates \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV="prod"

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

FROM ${RUNNER_IMAGE} AS runner

RUN apt-get update -y \
  && apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 locales ca-certificates \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG=en_US.UTF-8 \
    LANGUAGE=en_US:en \
    LC_ALL=en_US.UTF-8 \
    MIX_ENV=prod \
    CACHE_DATA_DIR=/var/lib/supacacher/cache

WORKDIR /app

RUN useradd --create-home --shell /bin/bash supacacher \
  && mkdir -p /var/lib/supacacher/cache \
  && chown -R supacacher:supacacher /app /var/lib/supacacher

COPY --from=builder --chown=supacacher:supacacher /app/_build/prod/rel/supacacher ./

USER supacacher

EXPOSE 4040 6380

CMD ["/app/bin/server"]
