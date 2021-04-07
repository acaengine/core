# One of `core` | `edge`
ARG TARGET=core

FROM crystallang/crystal:0.36.1-alpine as build

ARG PLACE_COMMIT=DEV
ARG TARGET

WORKDIR /app

# Install the latest version of LibSSH2, ping
RUN apk add --no-cache libssh2 libssh2-dev libssh2-static iputils yaml-static

# Add trusted CAs for communicating with external services
RUN apk update && apk add --no-cache ca-certificates tzdata && update-ca-certificates

# Create a non-privileged user
ARG IMAGE_UID="10001"
ENV UID=$IMAGE_UID
ENV USER=appuser
RUN adduser \
    --disabled-password \
    --gecos "" \
    --home "/nonexistent" \
    --shell "/sbin/nologin" \
    --no-create-home \
    --uid "${UID}" \
    "${USER}"

# Install deps
COPY shard.yml /app
COPY shard.override.yml /app
COPY shard.lock /app
RUN shards install --production --release --ignore-crystal-version

# Add source last for efficient caching
COPY src /app/src

# Build the required target
RUN UNAME_AT_COMPILE_TIME=true \
    PLACE_COMMIT=${PLACE_COMMIT} \
    shards build ${TARGET} --production --release --static --error-trace

# Create binary directories
RUN mkdir -p repositories bin/drivers
RUN chown appuser -R /app

###############################################################################

FROM scratch as minimal

WORKDIR /

# These are required for communicating with external services
COPY --from=build /etc/hosts /etc/hosts

# These provide certificate chain validation where communicating with external services over TLS
COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/

# This is required for Timezone support
COPY --from=build /usr/share/zoneinfo/ /usr/share/zoneinfo/

# Copy the user information over
COPY --from=build /etc/passwd /etc/passwd
COPY --from=build /etc/group /etc/group

# These provide certificate chain validation where communicating with external services over TLS
ENV SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt

# Service binary
COPY --from=build /app/bin /bin

USER appuser:appuser

###############################################################################

FROM minimal as edge

CMD ["/bin/edge"]

###############################################################################

# FIXME: core currently has a number of dependandancies on the runtime for
# retreiving repositories and compiling drivers. When the migrates into an
# external service, this can base from `minimal` instead for cleaner images.
FROM build as core

COPY --from=build /app/bin /bin

WORKDIR /app

USER appuser:appuser

EXPOSE 3000
HEALTHCHECK CMD wget -qO- http://localhost:3000/api/core/v1
CMD ["/bin/core", "-b", "0.0.0.0", "-p", "3000"]

###############################################################################

FROM ${TARGET}
