ifeq ($(shell test -f /run/.containerenv && echo y),y)
CRE ?= podman-remote
HOSTCURDIR := $(patsubst /run/host/%,%,$(CURDIR))
else
CRE ?= podman
HOSTCURDIR := $(CURDIR)
endif

MSTFLINT_IMAGE ?= mstflint
MSTFLINT_TAG ?= v4.37.0-1.3
MSTFLINT_VERSION := $(patsubst v%,%,$(MSTFLINT_TAG))
MSTFLINT_SHA := 1b8ac4b520390563ff0822d472a54895d033d143
MSTFLINT_CTX ?= build/mstflint-ctx

-include local.mk

.PHONY: image mstflint-ctx mstflint-image mstflint-deploy

# 1b8ac4b5 — merge relicense-dual2 (первый полностью dual-licensed
# коммит апстрима), достижим из origin/master. MSTFLINT_TAG — наш
# сборочный лейбл (версия патч-серии), у апстрима его нет: исходники
# пинятся SHA-литералом выше, shallow-fetch без истории.
mstflint-ctx:
	@mkdir -p build
	@scripts/safe-rm --under $(CURDIR) $(CURDIR)/$(MSTFLINT_CTX)
	@mkdir -p $(MSTFLINT_CTX)/mstflint
	git -C $(MSTFLINT_CTX)/mstflint init
	git -C $(MSTFLINT_CTX)/mstflint remote add origin https://github.com/Mellanox/mstflint
	git -C $(MSTFLINT_CTX)/mstflint fetch --depth 1 origin $(MSTFLINT_SHA)
	git -C $(MSTFLINT_CTX)/mstflint checkout FETCH_HEAD
	# eval_git_sha.sh (configure.ac:1031) вне git work-tree читает tools_git_sha
	# из корня исходников — без него все инструменты строятся с "Git SHA Hash: N/A".
	echo $(MSTFLINT_SHA) > $(MSTFLINT_CTX)/mstflint/tools_git_sha
	cp docker/mstflint.containerfile $(MSTFLINT_CTX)/
	cp patches/mstflint-4.37.0-1.1-data-path-env.patch $(MSTFLINT_CTX)/mstflint-data-path-env.patch
	cp patches/mstflint-4.37.0-1.3-secure-read-flag.patch $(MSTFLINT_CTX)/mstflint-secure-read-flag.patch
	cp scripts/mft-stage.sh $(MSTFLINT_CTX)/mft-stage.sh
	cp docker/mstflint-icon.png $(MSTFLINT_CTX)/mstflint-icon.png

image: mstflint-image

mstflint-image: mstflint-ctx
	$(CRE) build -f $(MSTFLINT_CTX)/mstflint.containerfile --build-arg MSTFLINT_SHA=$(MSTFLINT_SHA) --build-arg MSTFLINT_TAG=$(MSTFLINT_TAG) -t $(MSTFLINT_IMAGE):$(MSTFLINT_VERSION) $(MSTFLINT_CTX)

mstflint-deploy:
	@test -n "$(HOST)" || { echo "usage: make mstflint-deploy HOST=<ssh-alias>"; exit 2; }
	@$(CRE) image exists $(MSTFLINT_IMAGE):$(MSTFLINT_VERSION) >/dev/null 2>&1 || $(MAKE) mstflint-image
	@mkdir -p build
	@CTN=$$($(CRE) create $(MSTFLINT_IMAGE):$(MSTFLINT_VERSION)); \
	$(CRE) cp $$CTN:/opt/mft-artifacts/mstflint-$(MSTFLINT_VERSION)-x86_64.AppImage $(CURDIR)/build/mstflint-$(MSTFLINT_VERSION)-x86_64.AppImage && \
	$(CRE) cp $$CTN:/opt/mft-artifacts/manifest.txt $(CURDIR)/build/manifest.txt && \
	test -f $(CURDIR)/build/mstflint-$(MSTFLINT_VERSION)-x86_64.AppImage -a -f $(CURDIR)/build/manifest.txt; \
	rc=$$?; $(CRE) rm $$CTN >/dev/null; exit $$rc
	ssh $(HOST) 'mkdir -p /usr/local/share/mlxini-mstflint'
	scp $(CURDIR)/build/mstflint-$(MSTFLINT_VERSION)-x86_64.AppImage $(HOST):/usr/local/share/mlxini-mstflint/
	@BINS=$$(sed -n 's/^BIN=//p' $(CURDIR)/build/manifest.txt | tr '\n' ' '); \
	ssh $(HOST) "for n in $$BINS; do ln -sfn /usr/local/share/mlxini-mstflint/mstflint-$(MSTFLINT_VERSION)-x86_64.AppImage /usr/local/bin/\$$n; done"
