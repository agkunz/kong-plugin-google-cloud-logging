# Makefile for Kong Google Cloud Logging Plugin
# Variables
PLUGIN_NAME := kong-plugin-google-cloud-logging
VERSION := 0.1.1
NEW_VERSION := 0.1.2
REVISION := 1
ROCKSPEC := $(PLUGIN_NAME)-$(VERSION)-$(REVISION).rockspec
NEW_ROCKSPEC := $(PLUGIN_NAME)-$(NEW_VERSION)-$(REVISION).rockspec
ROCK := $(PLUGIN_NAME)-$(VERSION)-$(REVISION).all.rock
NEW_ROCK := $(PLUGIN_NAME)-$(NEW_VERSION)-$(REVISION).all.rock

# Default target
.PHONY: help
help: ## Show this help message
	@echo "Kong Google Cloud Logging Plugin - Available targets:"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'
	@echo ""

# Development targets
.PHONY: test
test: ## Run all tests with Busted
	@echo "🧪 Running tests..."
	export PATH="$$HOME/.luarocks/bin:$$PATH" && busted

.PHONY: test-watch
test-watch: ## Run tests in watch mode (requires entr)
	@echo "👀 Watching for changes and running tests..."
	find tests/ kong/ -name "*.lua" | entr -c make test

.PHONY: lint
lint: ## Lint Lua code (requires luacheck)
	@echo "🔍 Linting Lua code..."
	luacheck kong/ tests/ --std ngx_lua+busted

# Build targets
.PHONY: build
build: $(ROCK) ## Build the rock package

$(ROCK): $(ROCKSPEC)
	@echo "📦 Building rock package..."
	sudo luarocks make $(ROCKSPEC)
	luarocks pack $(PLUGIN_NAME) $(VERSION)

.PHONY: install
install: $(ROCK) ## Install the plugin locally
	@echo "📥 Installing plugin locally..."
	sudo luarocks install $(ROCK)

.PHONY: install-dev
install-dev: ## Install plugin in development mode
	@echo "🔧 Installing in development mode..."
	sudo luarocks make $(ROCKSPEC)

# Version management
.PHONY: bump-version
bump-version: ## Bump version from 0.1.1 to 0.1.2
	@echo "🚀 Bumping version from $(VERSION) to $(NEW_VERSION)..."
	@# Create new rockspec
	cp $(ROCKSPEC) $(NEW_ROCKSPEC)
	sed -i 's/version = "$(VERSION)-$(REVISION)"/version = "$(NEW_VERSION)-$(REVISION)"/' $(NEW_ROCKSPEC)
	@# Update pack.sh
	sed -i 's/$(PLUGIN_NAME) $(VERSION)/$(PLUGIN_NAME) $(NEW_VERSION)/' pack.sh
	@# Update Makefile version
	sed -i 's/VERSION := $(VERSION)/VERSION := $(NEW_VERSION)/' Makefile
	@echo "✅ Version bumped to $(NEW_VERSION)"
	@echo "📝 Don't forget to update README.md and commit changes!"

.PHONY: release
release: clean bump-version build ## Create a new release (bump version and build)
	@echo "🎉 Release $(NEW_VERSION) ready!"
	@echo "📦 Files created:"
	@echo "   - $(NEW_ROCKSPEC)"
	@echo "   - $(NEW_ROCK)"

# Utility targets
.PHONY: clean
clean: ## Clean build artifacts
	@echo "🧹 Cleaning build artifacts..."
	rm -f *.rock
	rm -f luarocks-*.log

.PHONY: clean-all
clean-all: clean ## Clean everything including old rockspecs
	@echo "🧹 Cleaning all artifacts..."
	rm -f kong-plugin-google-cloud-logging-*.rockspec

.PHONY: deps
deps: ## Install development dependencies
	@echo "📚 Installing development dependencies..."
	luarocks install --local busted
	luarocks install --local luacheck

# Kong specific targets
.PHONY: kong-dev
kong-dev: install-dev ## Setup for Kong development
	@echo "🦍 Plugin installed for Kong development"
	@echo "💡 Add 'google-cloud-logging' to your Kong plugins list"
	@echo "💡 Restart Kong to load the plugin"

.PHONY: kong-test
kong-test: ## Test plugin with Kong (requires Kong to be running)
	@echo "🦍 Testing with Kong..."
	@echo "💡 Make sure Kong is running and the plugin is configured"
	curl -i http://localhost:8001/plugins

# Docker targets (if you use Docker)
.PHONY: docker-test
docker-test: ## Run tests in Docker
	@echo "🐳 Running tests in Docker..."
	docker run --rm -v "$$PWD:/app" -w /app kong:3.4-alpine sh -c "luarocks install busted && busted"

# Development helpers
.PHONY: dev-setup
dev-setup: deps install-dev ## Full development environment setup
	@echo "🔧 Development environment ready!"
	@echo "💡 Try: make test"

.PHONY: status
status: ## Show plugin status
	@echo "📊 Plugin Status:"
	@echo "   Name: $(PLUGIN_NAME)"
	@echo "   Version: $(VERSION)"
	@echo "   Rockspec: $(ROCKSPEC)"
	@echo "   Rock: $(ROCK)"
	@echo ""
	@echo "📁 Files:"
	@ls -la *.rockspec *.rock 2>/dev/null || echo "   No packages built yet"
	@echo ""
	@echo "🧪 Tests:"
	@test -d tests/ && echo "   Tests found in tests/" || echo "   No tests directory"

# Git helpers
.PHONY: tag
tag: ## Create git tag for current version
	@echo "🏷️  Creating git tag v$(VERSION)..."
	git tag -a "v$(VERSION)" -m "Release version $(VERSION)"
	@echo "💡 Push with: git push origin v$(VERSION)"

.PHONY: changelog
changelog: ## Show recent commits for changelog
	@echo "📝 Recent commits (for changelog):"
	@git log --oneline -10
