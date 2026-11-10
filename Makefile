# nvimos backend: a Lua plugin that streams Neovim's state to an RPC client.
# Recipes run in pwsh (native Windows GNU make). Start with:  make help

SHELL       := pwsh.exe
.SHELLFLAGS := -NoProfile -NoLogo -Command

PORT ?= 6666

.PHONY: help test serve

# `make help` prints the `##@` lines as section headers and `target: ## text` as entries.
.DEFAULT_GOAL := help

##@ test

test: ## run the headless tests (T=<part of a name> runs only those)
	nvim -l test/run.lua $(T)

##@ run

serve: ## start Neovim on 127.0.0.1:6666 (PORT=) with the plugin loaded
	nvim --listen 127.0.0.1:$(PORT) --cmd 'set rtp^=$(CURDIR)'

##@ other

help: ## this list
	@Select-String -Path Makefile -Pattern '^##@ (.*)', '^([a-z-]+):.*## (.*)' | ForEach-Object { $$g = $$_.Matches[0].Groups; if ($$_.Line.StartsWith('##@')) { ''; $$g[1].Value } else { '  {0,-8} {1}' -f $$g[1].Value, $$g[2].Value } }
