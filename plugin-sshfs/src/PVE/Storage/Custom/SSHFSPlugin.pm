package PVE::Storage::Custom::MountPlugin;

use v5.36; # implies strict and warnings and enables method signature feature.

use base qw(PVE::Storage::Plugin);

# Plugin Definition

sub api {
    return 11;
}

sub type {
    return 'utilsmount';
}

sub plugindata {
    return {
        content => [
            {
                images => 1,
                rootdir => 1,
                vztmpl => 1,
                iso => 1,
                backup => 1,
                snippets => 1,
            },
            {
                images => 1,
                rootdir => 1,
            },
        ],
        format => [
            {
                raw => 1,
                qcow2 => 1,
                vmdk => 1,
            },
            'qcow2',
        ],
    };
}

sub properties {
    return {
        utils_remote_path => {
            description => "Path on the remote filesystem used for SSHFS. Must be absolute.",
            type => 'string',
            format => 'pve-storage-path',
        },
    };
}

sub options {
    return {
        disable => { optional => 1 },
        path => { fixed => 1 },
        'create-base-path' => { optional => 1 },
        content => { optional => 1 },
        'create-subdirs' => { optional => 1 },
        'content-dirs' => { optional => 1 },
        'prune-backups' => { optional => 1 },
        'max-protected-backups' => { optional => 1 },
        format => { optional => 1 },
        bwlimit => { optional => 1 },
        preallocation => { optional => 1 },
        nodes => { optional => 1 },
        shared => { optional => 1 },

        # SSHFS Options
        utils_remote_path => {},
    };
}

# Storage Implementation

sub on_add_hook($class, $storeid, $scfg, %sensitive) {
    die "error while adding SSHFS storage '${storeid}': $@\n" if $@;

    return undef;
}

sub on_update_hook($class, $storeid, $scfg, %sensitive) {
    die $@ if $@;

    return undef;
}

sub on_delete_hook($class, $storeid, $scfg) {
    warn $@ if $@;

    return undef;
}

sub check_connection($class, $storeid, $scfg) {
    return 1;
}

sub activate_storage($class, $storeid, $scfg, $cache) {
    $class->SUPER::activate_storage($storeid, $scfg, $cache);
    return;
}

sub get_volume_attribute($class, $scfg, $storeid, $volname, $attribute) {
    return undef;
}

sub update_volume_attribute($class, $scfg, $storeid, $volname, $attribute, $value) {

    die "attribute '$attribute' is not supported for storage type '$scfg->{type}'\n";
}

1;
