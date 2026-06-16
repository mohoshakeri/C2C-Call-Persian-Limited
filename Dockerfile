FROM mirror-docker.runflare.com/library/node:22-bookworm-slim

WORKDIR /app

ENV NODE_ENV="production"
ENV PORT=80

# APT Mirror and disable SSL
RUN sed -i 's/deb.debian.org/mirror-linux.runflare.com/g' /etc/apt/sources.list.d/debian.sources
RUN sed -i 's/security.debian.org/mirror-linux.runflare.com/g' /etc/apt/sources.list.d/debian.sources
RUN sed -i 's/https/http/g' /etc/apt/sources.list.d/debian.sources

# Copy package*.json dependencies
COPY package*.json ./

# Install necessary system packages and dependencies
RUN apt-get update
RUN apt-get install -y --no-install-recommends bash vim

RUN npm ci --omit=dev --silent --registry="https://mirror-npm.runflare.com" \
    npm cache clean --force \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* /usr/share/doc/*

# Copy the application code
COPY frontend frontend
COPY backend backend

EXPOSE 80

# Set default command to start the application
CMD ["npm", "start"]