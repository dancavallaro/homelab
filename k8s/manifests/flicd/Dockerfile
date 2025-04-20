FROM debian:bookworm-slim as base

RUN apt update && apt-get install -y git make g++

RUN git clone --depth 1 --branch 2.0.3 https://github.com/dancavallaro/fliclib-linux-hci.git
RUN cd fliclib-linux-hci/simpleclient && make


FROM debian:bookworm-slim

COPY --from=base /fliclib-linux-hci/bin/x86_64/flicd /flicd
COPY --from=base /fliclib-linux-hci/simpleclient/simpleclient /simpleclient

ENTRYPOINT ["/flicd"]
