IMAGE ?= claude-vertex:latest
BIN_DIR ?= $(HOME)/.local/bin
GCLOUD_VOL ?= claude-vertex-gcloud
HERE := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))

.DEFAULT_GOAL := help

.PHONY: help build rebuild auth run shell install uninstall clean reset-auth doctor

help: ## Show available targets
	@awk 'BEGIN{FS=":.*?## "}/^[a-zA-Z_-]+:.*?## /{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

build: ## Build the image
	docker build -t $(IMAGE) $(HERE)

rebuild: ## Rebuild the image without cache
	docker build --no-cache -t $(IMAGE) $(HERE)

auth: ## One-time gcloud ADC login (saved to docker volume, not host)
	$(HERE)/claude-vertex.sh auth

run: ## Run `claude` against the current directory
	$(HERE)/claude-vertex.sh

shell: ## Open a bash shell inside the container
	$(HERE)/claude-vertex.sh shell

install: ## Symlink wrapper to $(BIN_DIR)/claude-vertex
	mkdir -p $(BIN_DIR)
	ln -sf $(HERE)/claude-vertex.sh $(BIN_DIR)/claude-vertex
	@echo "installed: $(BIN_DIR)/claude-vertex"
	@echo "ensure $(BIN_DIR) is on PATH"

uninstall: ## Remove the wrapper symlink
	rm -f $(BIN_DIR)/claude-vertex

reset-auth: ## Wipe the gcloud creds volume (forces re-auth)
	docker volume rm $(GCLOUD_VOL) || true

clean: ## Remove the image
	docker rmi $(IMAGE) || true

doctor: ## Self-check: docker running, image built, auth volume populated
	@echo "== docker =="
	@docker version --format 'client: {{.Client.Version}}  server: {{.Server.Version}}' \
		|| { echo "  FAIL: docker not running"; exit 1; }
	@echo "== image =="
	@docker image inspect $(IMAGE) >/dev/null 2>&1 \
		&& echo "  ok: $(IMAGE) present" \
		|| echo "  MISSING: run 'make build'"
	@echo "== auth volume =="
	@docker volume inspect $(GCLOUD_VOL) >/dev/null 2>&1 \
		&& echo "  ok: volume $(GCLOUD_VOL) exists" \
		|| echo "  MISSING: run 'make auth'"
	@docker run --rm -v $(GCLOUD_VOL):/g alpine \
		test -f /g/application_default_credentials.json 2>/dev/null \
		&& echo "  ok: ADC credentials present" \
		|| echo "  MISSING ADC: run 'make auth'"
	@echo "== wrapper on PATH =="
	@command -v claude-vertex >/dev/null \
		&& echo "  ok: $$(command -v claude-vertex)" \
		|| echo "  MISSING: run 'make install' (or add $(BIN_DIR) to PATH)"
