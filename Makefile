.PHONY: help install uninstall lint clean

help:
	@echo "Agents Monitor — Makefile targets"
	@echo ""
	@echo "  make install     Install to ~/.local/ and ~/.config/, configure SwiftBar"
	@echo "  make uninstall   Run the uninstall script (interactive)"
	@echo "  make lint        bash -n syntax check on every shell script"
	@echo "  make clean       Remove backup files (*.bak, *.bak-*)"
	@echo ""

install:
	@./install.sh

uninstall:
	@if [ -x "$$HOME/.local/bin/agents-monitor-uninstall" ]; then \
	  "$$HOME/.local/bin/agents-monitor-uninstall"; \
	else \
	  ./bin/agents-monitor-uninstall; \
	fi

lint:
	@for f in install.sh bin/launchctl-user bin/agents-monitor-uninstall swiftbar/agents-monitor.30s.sh; do \
	  echo "--> $$f"; \
	  bash -n "$$f" && echo "    OK" || exit 1; \
	done

clean:
	@find . -maxdepth 2 -type f \( -name "*.bak" -o -name "*.bak-*" \) -delete -print
