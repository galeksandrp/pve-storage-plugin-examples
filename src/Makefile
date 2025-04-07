DESTDIR=
PREFIX=/usr

export PERLDIR=$(PREFIX)/share/perl5

all:

.PHONY: install
install: PVE
	$(MAKE) -C PVE install

.PHONY: clean
clean:
	$(MAKE) -C PVE clean
