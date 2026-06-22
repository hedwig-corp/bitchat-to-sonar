FROM golang:1.22-alpine AS builder

RUN apk add --no-cache git
WORKDIR /src
RUN git clone https://github.com/breez/notify.git . && \
    git checkout 54b1cdc4ae29 && \
    cd breezsdk/cmd && \
    CGO_ENABLED=0 go build -o /breez-nds .

FROM alpine:3.20
RUN apk add --no-cache ca-certificates wget
COPY --from=builder /breez-nds /usr/local/bin/breez-nds
USER nobody:nobody
ENTRYPOINT ["breez-nds"]
