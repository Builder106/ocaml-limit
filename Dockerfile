# Multi-stage Docker build for ocaml_lob.
#
# Stage 1 ("builder") uses the official OCaml/opam Ubuntu image to
# install dependencies and build the demo server and the perf suite.
# Stage 2 ("runtime") strips out the toolchain and ships only the two
# binaries plus the front/ assets, keeping the runtime image small and
# the attack surface minimal.
#
# The OCaml hot path is allocation-free per submit (see
# test/perf_test.ml), so one small container is enough for the live
# demo. The image runs the server by default; run ./perf_test to get
# the regression suite instead.

# ----------------------------------------------------------------------
# Stage 1: build
# ----------------------------------------------------------------------
FROM ocaml/opam:ubuntu-22.04-ocaml-5.6 AS builder

USER root
RUN apt-get update -y && \
    apt-get install -y --no-install-recommends \
    libssl-dev libgmp-dev libev-dev pkg-config m4 zlib1g-dev && \
    rm -rf /var/lib/apt/lists/*
USER opam

WORKDIR /home/opam/app

# Copy opam metadata first so layer caching kicks in: rebuilds of
# source code don't re-trigger the (slow) opam install step unless
# dependencies actually change.
COPY --chown=opam:opam dune-project ocaml_lob.opam ./

# Server libraries (dream pulls in lwt; lwt_ppx provides let%lwt) and
# the test framework for perf_test.
RUN opam update -y && \
    opam install --yes dream yojson lwt_ppx alcotest

COPY --chown=opam:opam dune ./
COPY --chown=opam:opam lib/ ./lib/
COPY --chown=opam:opam bin/ ./bin/
COPY --chown=opam:opam test/ ./test/

# [@chown] Docker creates WORKDIR with root ownership even after a
# `USER opam` directive, so dune can't write `_build/` underneath it.
RUN sudo chown -R opam:opam /home/opam/app && \
    eval $(opam env) && \
    dune build bin/server.exe test/perf_test.exe

# ----------------------------------------------------------------------
# Stage 2: runtime
# ----------------------------------------------------------------------
FROM ubuntu:26.04 AS runtime

LABEL org.opencontainers.image.source="https://github.com/Builder106/ocaml-limit"
LABEL org.opencontainers.image.description="Low-latency pure OCaml limit order book engine"

RUN apt-get update -y && \
    apt-get install -y --no-install-recommends \
    libssl3t64 libgmp10 libev4t64 ca-certificates && \
    rm -rf /var/lib/apt/lists/* && \
    useradd -r -s /usr/sbin/nologin -m -d /app ocaml

WORKDIR /app

COPY --from=builder --chown=ocaml:ocaml \
    /home/opam/app/_build/default/bin/server.exe ./server
COPY --from=builder --chown=ocaml:ocaml \
    /home/opam/app/_build/default/test/perf_test.exe ./perf_test
COPY --chown=ocaml:ocaml front/ ./front/

USER ocaml

ENV INTERFACE=0.0.0.0 PORT=8080
EXPOSE 8080
CMD ["./server"]
