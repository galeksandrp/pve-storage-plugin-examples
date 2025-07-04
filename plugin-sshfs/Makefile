# Makes useful Debian-specific variables available
include /usr/share/dpkg/default.mk

# --- Useful variables for convenience

# Note that variables can be overridden, e.g. `make install DESTDIR='./foo'`
DESTDIR=
PACKAGE=libpve-storage-plugin-sshfs-perl

BINDIR=${DESTDIR}/usr/bin
PERLLIBDIR=${DESTDIR}/usr/share/perl5
MAN1DIR=${DESTDIR}/usr/share/man/man1
MAN8DIR=${DESTDIR}/usr/share/man/man8
CRONDAILYDIR=${DESTDIR}/etc/cron.daily
INITDBINDIR=${DESTDIR}/etc/init.d
SERVICEDIR=${DESTDIR}/lib/systemd/system
BASHCOMPLDIR=${DESTDIR}/usr/share/bash-completion/completions/
ZSHCOMPLDIR=${DESTDIR}/usr/share/zsh/vendor-completions/
HARADIR=${DESTDIR}/usr/share/cluster
DOCDIR=${DESTDIR}/usr/share/doc/${PACKAGE}
PODDIR=${DESTDIR}/usr/share/doc/${PACKAGE}/pod
USRSHARE=${DESTDIR}/usr/share/${PACKAGE}

# Directory where our custom plugin has to go
PLUGINDIR=${PERLLIBDIR}/PVE/Storage/Custom

export VERSION = $(DEB_VERSION_UPSTREAM_REVISION)

BUILDDIR = $(PACKAGE)-$(DEB_VERSION_UPSTREAM)

DSC=$(PACKAGE)_$(DEB_VERSION).dsc
DEB=$(PACKAGE)_$(DEB_VERSION)_$(DEB_HOST_ARCH).deb

# --- Targets

$(BUILDDIR):
	rm -rf $@ $@.tmp
	mkdir $@.tmp
	rsync -a * $@.tmp
	# You can add additional commands instead of this comment if you need to
	# e.g. create additional files inside the build directory etc.
	mv $@.tmp $@

# Creates a .deb package for installation
.PHONY: deb
deb: $(DEB)
$(DEB): $(BUILDDIR)
	cd $(BUILDDIR); dpkg-buildpackage -b -us -uc
	lintian $(DEB)

# Creates a .dsc (Debian source) package
.PHONY: dsc
dsc:
	rm -rf $(BUILDDIR) $(DSC)
	$(MAKE) $(DSC)
	lintian $(DSC)

$(DSC): $(BUILDDIR)
	cd $(BUILDDIR); dpkg-buildpackage -S -us -uc -d

# Target used to place files and directories at expected locations, with expected permissions
.PHONY: install
install:
	install -D -m 0644 src/PVE/Storage/Custom/SSHFSPlugin.pm $(PLUGINDIR)/SSHFSPlugin.pm

# Used to clean up your builds
.PHONY: clean
clean:
	rm -f $(PACKAGE)*.tar* *.deb *.dsc *.build *.buildinfo *.changes
	rm -rf dest $(PACKAGE)-[0-9]*/
