include /usr/share/dpkg/default.mk

PACKAGE=libpve-storage-backup-directory-perl

BUILDDIR ?= $(PACKAGE)-$(DEB_VERSION)
DSC=$(PACKAGE)_$(DEB_VERSION).dsc

DEB=$(PACKAGE)_$(DEB_VERSION_UPSTREAM_REVISION)_all.deb

all: $(DEB)

$(BUILDDIR): debian
	rm -rf $@ $@.tmp
	cp -a src $@.tmp
	cp -a debian/ $@.tmp/
	mv $@.tmp $@

.PHONY: deb
deb: $(DEB)
$(DEB): $(BUILDDIR)
	cd $(BUILDDIR); dpkg-buildpackage -b -us -uc
	lintian $(DEB)

.PHONY: dsc
dsc: $(DSC)
$(DSC): $(BUILDDIR)
	cd $(BUILDDIR); dpkg-buildpackage -S -us -uc -d
	lintian $(DSC)

.PHONY: sbuild
sbuild: $(DSC)
	sbuild $(DSC)

.PHONY: distclean
distclean: clean

.PHONY: clean
clean:
	rm -rf $(PACKAGE)-[0-9]*/ $(PACKAGE)*.tar.* *.deb *.dsc *.changes *.build *.buildinfo
