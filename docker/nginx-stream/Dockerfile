FROM alpine:3.21

RUN apk add --no-cache nginx nginx-mod-stream ca-certificates

STOPSIGNAL SIGQUIT
CMD ["nginx", "-g", "daemon off;"]
