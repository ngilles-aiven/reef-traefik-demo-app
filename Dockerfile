# reef-traefik-demo-app
#
# A single image that runs BOTH:
#   1. the exact `whoami` binary shipped in the traefik/whoami image, and
#   2. its own Traefik instance reverse-proxying to it.
#
# Both are statically-linked Go binaries, so we just copy them in — no build.

# Grab the whoami binary from the official image.
FROM traefik/whoami:v1.12 AS whoami

# Base on the official Traefik image: this gives us the Traefik binary at
# /usr/local/bin/traefik, a POSIX shell (alpine), and CA certificates.
FROM traefik:v3.7

# The exact whoami binary from traefik/whoami.
COPY --from=whoami /whoami /usr/local/bin/whoami

# Traefik config (static + dynamic) and our process launcher.
COPY traefik/ /etc/traefik/
COPY entrypoint.sh /entrypoint.sh

# 80   -> Traefik "web" entrypoint (public HTTP)
# 8080 -> Traefik dashboard/API
EXPOSE 80 8080

ENTRYPOINT ["/entrypoint.sh"]
