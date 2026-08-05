.PHONY: build up down logs sh restart

# Build the image.
build:
	docker compose build

# Start the demo in the background.
up:
	docker compose up -d --build

# Stop and remove the container.
down:
	docker compose down

# Follow container logs.
logs:
	docker compose logs -f

# Open a shell inside the running container.
sh:
	docker compose exec reef-traefik-demo /bin/sh

# Restart (needed after editing the static traefik.yml).
restart:
	docker compose restart
