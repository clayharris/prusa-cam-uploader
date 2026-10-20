FROM alpine:3
RUN apk add --no-cache curl jq tini
COPY uploader.sh healthcheck.sh /usr/local/bin/
RUN chmod 755 /usr/local/bin/uploader.sh /usr/local/bin/healthcheck.sh
USER nobody
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD ["/usr/local/bin/healthcheck.sh"]
ENTRYPOINT ["/sbin/tini", "--"]
CMD ["/usr/local/bin/uploader.sh"]
