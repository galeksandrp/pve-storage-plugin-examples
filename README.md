# Proxmox VE Storage Plugin Examples

This repository contains example plugins for the Proxmox VE external storage and backup providers
interface.

Currently, the storage plugin must be written in Perl, but with, e.g., Foreign Function Interface
(FFI) or Inter-Process Communication (IPC) mechanisms, it could be a thin wrapper around a client
written in a programming language of your choice.

## License and Copyright

As long as you honor the copyright notice included in the "debian/copyright" folder of each plugin,
you are free to copy and adapt from these examples. This typically requires licensing the *plugin
code*–but not the code of your storage implementation–under AGPL 3+ as the result would be a
derivative work.

Your plugin must be compatible with Proxmox VE licensed under AGPL 3+ in any way. So you must
license your *plugin* code accordingly, even if you don't use any of our derivative works. In
addition to the AGPL 3+ license, options include the GPL 3+, the Mozilla Public License 2.0, or a
combination of Apache 2.0 and MIT. Using licenses besides AGPL 3+ will significantly limit the
amount of our (Perl) library modules you can use.

Note that your storage itself does **not** need to be licensed under this copyleft license. The
plugin can mostly be a wrapper around your existing client API or ABI through an IPC mechanism, such
as running external commands using fork/exec, Unix sockets, pipes, or FIFO file descriptors, or a
network API.

## See Also

For some more information see <https://pve.proxmox.com/wiki/Storage_Plugin_Development>.
