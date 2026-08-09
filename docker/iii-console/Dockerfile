FROM alpine:3.22.1 AS download

ARG III_CONSOLE_VERSION
ARG III_CONSOLE_SHA256

RUN apk add --no-cache ca-certificates \
    && wget -q -O /tmp/iii-console.tar.gz \
      "https://github.com/iii-hq/iii/releases/download/iii%2Fv${III_CONSOLE_VERSION}/iii-console-x86_64-unknown-linux-musl.tar.gz" \
    && echo "${III_CONSOLE_SHA256}  /tmp/iii-console.tar.gz" | sha256sum -c - \
    && tar -xzf /tmp/iii-console.tar.gz -C /tmp \
    && /tmp/iii-console --version

FROM alpine:3.22.1

RUN apk add --no-cache ca-certificates

COPY --from=download /tmp/iii-console /usr/local/bin/iii-console

ENV HOME=/tmp
USER 65532:65532
EXPOSE 3114

ENTRYPOINT ["iii-console"]
