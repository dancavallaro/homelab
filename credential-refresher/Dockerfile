FROM golang:1.22.5-bookworm as base

WORKDIR /
COPY . /src
RUN cd src && go build -o credential-refresher main.go


FROM debian:bookworm-slim as credential-refresher

WORKDIR /

RUN apt update && apt-get install -y ca-certificates

COPY --from=base /src/credential-refresher /credential-refresher

ENTRYPOINT ["/credential-refresher"]
