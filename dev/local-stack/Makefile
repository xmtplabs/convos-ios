# Convos local stack — committed in convos-ios, runs an EXTERNAL shared workspace.
# Usage from a convos-ios checkout:  make -C dev/local-stack <target>
# (or the Claude commands /run local and /local-stack). See README.md.
#
# `make up` is the FULL stack (backend + Postgres + herald + assistants/Hermes + MinIO) —
# what most iOS devs need, since the agents backend is core to the app.

SHELL := /bin/bash
STACK := bash ./stack.sh
export CONVOS_REPOS_DIR

.DEFAULT_GOAL := help

.PHONY: help init bootstrap up up-core down restart status logs hermes-build ios-config doctor clean nuke

help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

init: ## First-time: choose a workspace dir + clone the service repos into it (WS=/path optional)
	@$(STACK) init "$(WS)"

bootstrap: ## One-time per machine: deps, secrets (1Password), env files, migrations
	@$(STACK) bootstrap

up: ## Start the FULL stack — the default
	@$(STACK) up full

up-core: ## Start only backend + Postgres (no agents) — escape hatch
	@$(STACK) up core

down: ## Stop host services + infra (keeps data volumes)
	@$(STACK) down

restart: ## down + up (full)
	@$(STACK) down && $(STACK) up full

status: ## Health of every service + Docker cap + load
	@$(STACK) status

logs: ## Tail host-service logs (SVC=backend|herald|worker to scope)
	@$(STACK) logs $(SVC)

hermes-build: ## Pre-build the Hermes container image (capped)
	@$(STACK) hermes-build

ios-config: ## Configure a convos-ios checkout as a Local thin client (IOS=/path; default: this repo)
	@$(STACK) ios-config "$(IOS)"

doctor: ## Check prereqs + Docker CPU cap (no changes)
	@$(STACK) doctor

clean: ## Stop + remove host-service run state
	@$(STACK) clean

nuke: ## clean + drop docker volumes (Postgres + MinIO data) — destructive
	@$(STACK) nuke
