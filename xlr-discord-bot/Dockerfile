FROM node:20-alpine

# Tools needed at runtime
RUN apk add --no-cache git tini

ENV APP_DIR=/opt/xlrbot
WORKDIR $APP_DIR

# Prepare app dir and permissions for the non-root user
RUN mkdir -p $APP_DIR && chown -R node:node $APP_DIR

# Copy entrypoint
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

USER node
ENV NODE_ENV=production

# PID 1 handling
ENTRYPOINT ["/sbin/tini","--"]
CMD ["/entrypoint.sh"]

HEALTHCHECK --interval=30s --timeout=3s --retries=5 CMD \
  test -f /opt/xlrbot/health/ready && \
  find /opt/xlrbot/health/ready -mmin -0.1 >/dev/null 2>&1 || exit 1
