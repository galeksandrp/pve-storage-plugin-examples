SOURCES = BackupProviderDirExamplePlugin.pm \
          BorgBackupPlugin.pm

.PHONY: install
install:
	for i in ${SOURCES}; do install -D -m 0644 $$i ${DESTDIR}${PERLDIR}/PVE/Storage/Custom/$$i; done
