# realmd — clean-room Zig Battle.net/D2 realm server (pvpgn replacement).
#
# Two-stage: build a static musl binary with zig, ship it in scratch. The result
# is a few-MB image with zero runtime deps.
#
#   docker build -f deploy/Dockerfile -t realmd:latest .
FROM alpine:3.20 AS build
RUN apk add --no-cache curl xz
ARG ZIG_VERSION=0.16.0
RUN curl -sSL https://ziglang.org/download/${ZIG_VERSION}/zig-linux-x86_64-${ZIG_VERSION}.tar.xz \
      | tar -xJ -C /opt && ln -s /opt/zig-linux-x86_64-${ZIG_VERSION}/zig /usr/local/bin/zig
WORKDIR /src
COPY build.zig ./
COPY src ./src
RUN zig build install -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSafe

FROM scratch
COPY --from=build /src/zig-out/bin/realmd /realmd
# bnetd / d2cs / d2dbs / gs-link
EXPOSE 6112 6113 6114 6115
ENTRYPOINT ["/realmd"]
