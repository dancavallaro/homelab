FROM debian:bookworm-slim as base

RUN apt update && apt-get install -y git make g++

RUN git clone --depth 1 --branch 2.0.3 https://github.com/dancavallaro/fliclib-linux-hci.git
RUN cd fliclib-linux-hci/simpleclient && make


FROM ubuntu:24.04

RUN apt update && apt install -y sqlite3

#COPY --from=base /fliclib-linux-hci/bin/x86_64/flicd /flicd
# Workaround for https://github.com/50ButtonsEach/fliclib-linux-hci/issues/117
ADD ./flicd /flicd
COPY --from=base /fliclib-linux-hci/simpleclient/simpleclient /simpleclient

ENTRYPOINT ["/flicd"]
