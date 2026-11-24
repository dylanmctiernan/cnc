# grblHAL simulator exposing a raw TCP (telnet) port, preconfigured for the
# planned machine. Upstream marks the simulator proof-of-concept, so the
# commit is pinned.
# Trixie: the grblHAL core needs strlcpy (glibc >= 2.38).
FROM debian:trixie-slim AS build
ARG GRBLHAL_SIM_COMMIT=9d1a390b2bcdfc8a82f2c99523cac58a3511b983
RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential cmake git ca-certificates \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /src
RUN git clone https://github.com/grblHAL/Simulator.git . \
 && git checkout "$GRBLHAL_SIM_COMMIT" \
 && git submodule update --init --recursive
# Only the simulator: the validator target doesn't link at this commit.
RUN cmake -S . -B build -DCMAKE_BUILD_TYPE=Release \
 && cmake --build build -j --target grblHAL_sim \
 && install build/grblHAL_sim /usr/local/bin/

# Bake settings into the EEPROM file at build time. Configuring at runtime
# would race the host: the simulator hands the stream to whichever TCP
# client connected last.
COPY settings.conf /etc/grblhal/settings.conf
COPY configure.sh /usr/local/bin/configure.sh
RUN mkdir /data && configure.sh

FROM debian:trixie-slim
COPY --from=build /usr/local/bin/grblHAL_sim /usr/local/bin/grblHAL_sim
COPY --from=build /data /data
WORKDIR /data
EXPOSE 2323
CMD ["grblHAL_sim", "-p", "2323"]
