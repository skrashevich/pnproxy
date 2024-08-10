# syntax=docker/dockerfile:labs

ARG GO_VERSION="1.22"
ARG TESTDOMAIN="navalny.com"
ARG TESTVIDEO="https://www.youtube.com/watch?v=2oQZpxtqi08"
ARG TESTVIDEODOMAIN="www.youtube.com"

###
### TEST 
### docker buildx build --target test -t pnproxy:test --load . && docker run -it --rm pnproxy:test
FROM --platform=$BUILDPLATFORM golang:${GO_VERSION}-alpine AS test
ARG TESTDOMAIN
ARG TESTVIDEODOMAIN

ADD --link . /pnproxy
WORKDIR /pnproxy
RUN apk --no-cache add curl gcc musl-dev yt-dlp
RUN CGO_ENABLED=1 go build && cp pnproxy /usr/local/bin/ && go clean -cache -modcache 

COPY <<EOF /etc/pnproxy.yaml
hosts:
  test: ${TESTDOMAIN}
  testvideo: ${TESTVIDEODOMAIN}

dns:
  listen: ":53"
  rules:
    - name: test testvideo
      action: static address 127.0.0.1 
  default:
    action: doh provider cloudflare cache true
tls:
  listen: ":443"
  rules:
    - name: test 
      action: split_pass sleep 100/1ms
    - name: testvideo
      action: host_obfuscate
EOF

COPY --chmod=755 <<EOF /usr/local/bin/test.sh
#!/bin/sh

pnproxy -config /etc/pnproxy.yaml &

sleep 3

export OLDRESOLVCONF=$(cat /etc/resolv.conf)

echo "Testing access without pnproxy:"
curl --connect-timeout 5 -I https://${TESTDOMAIN}

echo "nameserver 127.0.0.1" > /etc/resolv.conf

echo "Testing access with pnproxy:"
curl --connect-timeout 5 -I https://${TESTDOMAIN}

echo "Testing video with pnproxy:"
yt-dlp --force-overwrites 'https://www.youtube.com/watch?v=2oQZpxtqi08'

echo "$OLDRESOLVCONF" > /etc/resolv.conf
echo "Testing video without pnproxy:"
yt-dlp --force-overwrites 'https://www.youtube.com/watch?v=2oQZpxtqi08'
read
killall pnproxy
EOF

CMD ["/usr/local/bin/test.sh"]
###
### END TEST
###


# 1. Build binary
FROM --platform=$BUILDPLATFORM golang:${GO_VERSION}-alpine AS build
ARG TARGETPLATFORM
ARG TARGETOS
ARG TARGETARCH

ENV GOOS=${TARGETOS}
ENV GOARCH=${TARGETARCH}

WORKDIR /build

# Cache dependencies
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/root/.cache/go-build go mod download

COPY . .
RUN --mount=type=cache,target=/root/.cache/go-build CGO_ENABLED=0 go build -ldflags "-s -w" -trimpath


# 2. Final image
FROM alpine

# Install tini (for signal handling)
RUN apk add --no-cache tini

COPY --from=build /build/pnproxy /usr/local/bin/

ENTRYPOINT ["/sbin/tini", "--"]
VOLUME /config
WORKDIR /config

CMD ["pnproxy", "-config", "/config/pnproxy.yaml"]
