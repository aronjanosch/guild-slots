LUAJIT ?= luajit

.PHONY: test vectors sounds media zip

test:
	$(LUAJIT) tests/run.lua
	$(LUAJIT) tests/run.lua --unsigned

vectors:
	@if [ -f tools/ref/gen_vectors.py ]; then \
		python3 tools/ref/gen_vectors.py; \
	else \
		echo "tools/ref/gen_vectors.py not present, nothing to regenerate"; \
	fi

sounds:
	python3 tools/gen_sounds.py

media:
	python3 tools/build_media.py

# Build the distributable archive: dist/GuildSlots-<version>.zip, unpacked into Interface/AddOns.
VERSION := $(shell sed -n 's/^## Version: //p' GuildSlots/GuildSlots.toc)
zip:
	mkdir -p dist
	rm -f dist/GuildSlots-$(VERSION).zip
	git archive --format=zip -o dist/GuildSlots-$(VERSION).zip HEAD GuildSlots
