SCRIPTS := bin/upb install.sh proxmox/pbs-setup.sh \
	$(wildcard lib/*.sh) $(wildcard tests/stubs/*) tests/test_helper.bash
CONFIGS := config/upb.conf.example config/host-backup.conf.example $(wildcard config/jobs.d/*.example)

.PHONY: check lint test

check: lint test

lint:
	shellcheck -x $(SCRIPTS)
	shellcheck -x tests/*.bats
	shellcheck --shell=bash --exclude=SC2034 $(CONFIGS)

test:
	bats tests
