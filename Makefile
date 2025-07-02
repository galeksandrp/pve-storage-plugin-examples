# Just some convenience targets for executing a make target over all examples.
#
# These are just some convenience targets for executing a 'make' target over
# all the examples.
#
# If you use this as a template for your PVE storage or backup plugin, you will
# usually just want to use the folder of the example that most closely matches
# your feature set and use case as a base.

SUBDIRS := \
 backup-provider-borg \
 backup-provider-directory \

.PHONY: deb dsc sbuild clean
deb:
	for dir in $(SUBDIRS); do $(MAKE) -C "$$dir" $@; done

dsc:
	for dir in $(SUBDIRS); do $(MAKE) -C "$$dir" $@; done

sbuild:
	for dir in $(SUBDIRS); do $(MAKE) -C "$$dir" $@; done

clean:
	for dir in $(SUBDIRS); do $(MAKE) -C "$$dir" $@; done
