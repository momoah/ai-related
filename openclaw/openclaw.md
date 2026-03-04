cat > Containerfil << EOF
FROM registry.access.redhat.com/ubi9/ubi-minimal

# Install only essential build tools and clean up in the same layer
RUN microdnf install -y git tar xz make gcc gcc-c++ python3 cmake && \
    microdnf clean all && \
    rm -rf /var/cache/microdnf/*

# Download and install Node.js 22 manually
RUN curl -fsSL https://nodejs.org/dist/v22.12.0/node-v22.12.0-linux-x64.tar.xz | tar -xJ -C /usr/local --strip-components=1 && \
    npm cache clean --force

# Create a non-root user
RUN useradd -u 1001 -r -g 0 -m -s /sbin/nologin -c "Default Application User" openclaw && \
    mkdir -p /app /home/openclaw/.openclaw && \
    chown -R openclaw:0 /app /home/openclaw

# Set working directory
WORKDIR /app

# Configure npm to use HTTPS instead of SSH for GitHub
RUN git config --global url."https://github.com/".insteadOf ssh://git@github.com/

# Install OpenClaw and clean up
USER 0
RUN npm install -g --force openclaw@latest && \
    PLUGIN_FILE="$(npm root -g)/openclaw/extensions/minimax-portal-auth/index.ts" && \
    if [ -f "$PLUGIN_FILE" ]; then sed -i.bak 's/clawdbot\/plugin-sdk/openclaw\/plugin-sdk/g' "$PLUGIN_FILE"; fi && \
    openclaw plugins enable minimax-portal-auth && \
    npm cache clean --force && \
    rm -rf /root/.npm && \
    rm -rf /usr/share/man /usr/share/doc

# Copy default config and fix ownership in one shot
COPY --chown=1001:0 entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
USER 1001
EXPOSE 3000
CMD ["/entrypoint.sh"]

# $ podman run -v ./openclaw.json:/etc/openclaw/openclaw.json:Z,ro -v openclaw-state:/home/openclaw/.openclaw -p 3000:3000 localhost/openclaw:latest

EOF

cat > openclaw.json << EOF
{
  "auth": {
    "profiles": {
      "ollama:manual": {
        "provider": "ollama",
        "mode": "token"
      }
    }
  },
  "models": {
    "providers": {
      "ollama": {
        "baseUrl": "http://host.containers.internal:11434",
        "models": [
          {
            "id": "llama3.2",
            "name": "llama3.2"
          }
        ]
      }
    }
  },
  "agents": {
    "defaults": {
      "model": {
        "primary": "ollama/llama3.2"
      }
    }
  },
  "commands": {
    "native": "auto",
    "nativeSkills": "auto",
    "restart": true,
    "ownerDisplay": "raw"
  },
  "gateway": {
    "port": 3000,
    "mode": "local",
    "bind": "lan",
    "controlUi": {
      "dangerouslyAllowHostHeaderOriginFallback": true
    }
  }
}
EOF

export OPENCLAW_GATEWAY_TOKEN_GEN=`openssl rand -hex 32`

Run with anthropic API:
podman run \
  -v ./openclaw.json:/etc/openclaw/openclaw.json:Z,ro \
  -v openclaw-state:/home/openclaw/.openclaw \
  -e ANTHROPIC_API_KEY={get this from https://platform.claude.com/settings/keys} \
  -p 3000:3000 \
  localhost/openclaw:latest

Run with Ollama API:
# Run Ollama
podman run -d --name ollama \
  -v ollama-models:/root/.ollama \
  -p 11434:11434 \
  ollama/ollama

# or with GPU if you have:
$ podman rm -f ollama
podman run -d --name ollama \
  -v ollama-models:/root/.ollama \
  -p 11434:11434 \
  --device /dev/kfd \
  --device /dev/dri \
  --group-add video \
  --security-opt seccomp=unconfined \
  -e HSA_OVERRIDE_GFX_VERSION=10.3.2 \
  ollama/ollama:rocm
ollama


podman run -d \
  -v ./openclaw.json:/etc/openclaw/openclaw.json:Z,ro \
  -v openclaw-state:/home/openclaw/.openclaw \
  -e OLLAMA_API_KEY=ollama \
  -p 3000:3000 \
  --name openclaw \
  localhost/openclaw:latest
