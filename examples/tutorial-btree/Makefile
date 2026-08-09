# Page manager smoke test for docs/tutorial-btree.md.
#
# This directory ships the §2 page manager, which is verified. The full
# B-tree (node splits, insert, iteration, CLI) is what the tutorial walks you
# through building on top of it -- it is deliberately not shipped here.
KRC ?= ../../build/krc2

all: pager_test

pager_test: main.kr pager.kr
	$(KRC) --arch=$(shell uname -m | sed 's/aarch64/arm64/') main.kr -o pager_test

check: pager_test
	@./pager_test && echo "check: OK" || { echo "check: FAILED"; exit 1; }

clean:
	rm -f pager_test /tmp/kr_tutorial_btree.db

.PHONY: all check clean
