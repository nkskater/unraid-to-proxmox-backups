SCRIPTS := bin/upb install.sh proxmox/pbs-setup.sh unraid/user-scripts/upb-backup/script \
	$(wildcard lib/*.sh) $(wildcard tests/stubs/*) tests/test_helper.bash
CONFIGS := config/upb.conf.example $(wildcard config/jobs.d/*.example)

.PHONY: check lint test

check: lint test

lint:
	shellcheck -x $(SCRIPTS)
	shellcheck -x tests/*.bats
	shellcheck --shell=bash --exclude=SC2034,SC2317 $(CONFIGS)

test:
	bats tests
