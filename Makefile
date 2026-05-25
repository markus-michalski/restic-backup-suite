SCRIPTS := backup.sh restore.sh install.sh config.example.sh

.PHONY: install uninstall lint check release help

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'

install: ## Install system-wide (runs install.sh)
	@bash install.sh

install-cron: ## Install with daily cron job
	@bash install.sh --cron

uninstall: ## Remove system-wide installation
	@bash install.sh --uninstall

lint: ## Run ShellCheck on all scripts
	@shellcheck $(SCRIPTS)
	@echo "ShellCheck: all clean"

check: lint ## Run all checks

release: ## Tag and push a release (usage: make release VERSION=1.2.0)
	@[ -n "$(VERSION)" ] || { echo "Usage: make release VERSION=x.y.z"; exit 1; }
	@git diff --quiet && git diff --cached --quiet || { echo "Uncommitted changes — commit first"; exit 1; }
	@grep -q "\[$(VERSION)\]" CHANGELOG.md || { echo "No [$(VERSION)] entry in CHANGELOG.md — add it first"; exit 1; }
	git tag -a "v$(VERSION)" -m "Release v$(VERSION)"
	git push origin "v$(VERSION)"
	gh release create "v$(VERSION)" \
		--title "v$(VERSION)" \
		--notes-from-tag \
		--verify-tag
	@echo "Released v$(VERSION)"
