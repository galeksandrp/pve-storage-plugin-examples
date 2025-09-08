package PVE::Storage::Custom::SSHFSPlugin;

use v5.36; # implies strict and warnings and enables method signature feature.

use Cwd qw();
use Encode qw(decode encode);
use File::Path qw(make_path);
use File::Basename qw(dirname);
use IO::File;
use POSIX qw(:errno_h);

use PVE::ProcFSTools;
use PVE::Tools qw(
    file_copy
    file_get_contents
    file_set_contents
    run_command
);

use base qw(PVE::Storage::Plugin);

# Plugin Definition

sub api {
    return 11;
}

sub type {
    return 'sshfs';
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
        'sensitive-properties' => {
            'sshfs-private-key' => 1,
        },
    };
}

sub properties {
    return {
        'remote-path' => {
            description => "Path on the remote filesystem used for SSHFS. Must be absolute.",
            type => 'string',
            format => 'pve-storage-path',
        },
        'sshfs-private-key' => {
            description => "The private key to use for SSHFS.",
            type => 'string',
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
        username => {},
        server => {},
        'remote-path' => {},
        port => { optional => 1 },
        'sshfs-private-key' => { optional => 1 },
    };
}

# SSHFS Helpers

my sub sshfs_remote_from_config : prototype($) ($scfg) {
    my ($user, $host, $remote_path) = $scfg->@{qw(username server remote-path)};
    return "${user}\@${host}:${remote_path}";
}

my sub sshfs_private_key_path : prototype($) ($storeid) {
    return "/etc/pve/priv/storage/$storeid.key";
}

my sub sshfs_known_hosts_path : prototype($) ($storeid) {
    return "/etc/pve/priv/storage/${storeid}_known_hosts";
}

my sub sshfs_common_ssh_opts : prototype($) ($storeid) {
    my $private_key_path = sshfs_private_key_path($storeid);
    my $known_hosts_path = sshfs_known_hosts_path($storeid);

    my @common_opts = (
        '-o',
        "UserKnownHostsFile=${known_hosts_path}",
        '-o',
        'GlobalKnownHostsFile=none',
        '-o',
        "IdentityFile=${private_key_path}",
        '-o',
        "StrictHostKeyChecking=accept-new",
    );

    return @common_opts;
}

my sub sshfs_set_private_key : prototype($$) ($storeid, $key) {
    my $key_path = sshfs_private_key_path($storeid);

    my $key_parent_dir = dirname($key_path);
    if (!-e $key_parent_dir) {
        # We don't need to set the mode here as pmxcfs sets it itself
        make_path($key_parent_dir);
    }

    # Same here; pmxcfs sets the mode itself, so we don't need to here
    file_set_contents($key_path, "$key\n");

    return undef;
}

my sub sshfs_remove_private_key : prototype($) ($storeid) {
    my $key_path = sshfs_private_key_path($storeid);

    if (!unlink $key_path) {
        return if $! == ENOENT;
        die "failed to remove private key '$key_path' - $!\n";
    }

    return undef;
}

my sub sshfs_remove_known_hosts : prototype($) ($storeid) {
    my $known_hosts_path = sshfs_known_hosts_path($storeid);

    if (!unlink $known_hosts_path) {
        return if $! == ENOENT;
        die "failed to remove known_hosts file '$known_hosts_path' - $!\n";
    }

    return undef;
}

my sub sshfs_is_mounted : prototype($) ($scfg) {
    my $remote = sshfs_remote_from_config($scfg);

    my $mountpoint = Cwd::realpath($scfg->{path}); # Resolve symlinks
    return 0 if !defined($mountpoint);

    my $mountdata = PVE::ProcFSTools::parse_proc_mounts();

    my $has_found_mountpoint = grep {
        $_->[0] =~ m|^\Q${remote}\E$|
            && $_->[1] eq $mountpoint
            && $_->[2] eq 'fuse.sshfs'
    } $mountdata->@*;

    return $has_found_mountpoint != 0;
}

my sub sshfs_mount : prototype($$) ($scfg, $storeid) {
    my $remote = sshfs_remote_from_config($scfg);
    my ($port, $mountpoint) = $scfg->@{qw(port path)};

    my @common_opts = sshfs_common_ssh_opts($storeid);
    my $cmd = [
        '/usr/bin/sshfs', @common_opts, '-o', 'noatime',
    ];

    push($cmd->@*, '-p', $port) if $port;
    push($cmd->@*, $remote, $mountpoint);

    eval {
        run_command(
            $cmd,
            timeout => 10,
            errfunc => sub { warn "$_[0]\n"; },
        );
    };
    if (my $err = $@) {
        die "failed to mount SSHFS storage '$remote' at '$mountpoint': $@\n";
    }

    die "SSHFS storage '$remote' not mounted at '$mountpoint' despite reported success\n"
        if !sshfs_is_mounted($scfg);

    return;
}

my sub sshfs_umount : prototype($) ($scfg) {
    my $mountpoint = $scfg->{path};

    my $cmd = ['/usr/bin/umount', $mountpoint];

    eval {
        run_command(
            $cmd,
            timeout => 10,
            errfunc => sub { warn "$_[0]\n"; },
        );
    };
    if (my $err = $@) {
        die "failed to unmount SSHFS at '$mountpoint': $err\n";
    }

    return;
}

# Storage Implementation

sub on_add_hook($class, $storeid, $scfg, %sensitive) {
    $scfg->{shared} = 1; # mark SSHFS storages as shared by default

    eval {
        if (defined(my $key = delete $sensitive{'sshfs-private-key'})) {
            sshfs_set_private_key($storeid, $key);
        }
    };
    die "error while adding SSHFS storage '${storeid}': $@\n" if $@;

    return undef;
}

sub on_update_hook($class, $storeid, $scfg, %sensitive) {
    if (exists($sensitive{'sshfs-private-key'})) {
        if (defined($sensitive{'sshfs-private-key'})) {
            eval { sshfs_set_private_key($storeid, $sensitive{'sshfs-private-key'}) };
            die $@ if $@;

        } else {
            warn "removing private key for SSHFS storage '${storeid}'";
            warn "the storage might not be mountable without a private key!";

            eval { sshfs_remove_private_key($storeid); };
            die $@ if $@;
        }
    }

    return undef;
}

sub on_delete_hook($class, $storeid, $scfg) {
    eval { sshfs_remove_private_key($storeid); };
    warn $@ if $@;

    eval { sshfs_remove_known_hosts($storeid); };
    warn $@ if $@;

    eval { sshfs_umount($scfg) if sshfs_is_mounted($scfg); };
    warn $@ if $@;

    return undef;
}

sub check_connection($class, $storeid, $scfg) {
    my ($user, $host, $port) = $scfg->@{qw(username server port)};

    my @common_opts = sshfs_common_ssh_opts($storeid);
    my $cmd = [
        '/usr/bin/ssh', '-T', @common_opts, '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=5',
    ];

    push($cmd->@*, "-p", $port) if $port;
    push($cmd->@*, "${user}\@${host}", 'exit 0');

    eval {
        run_command(
            $cmd,
            timeout => 10,
            errfunc => sub { warn "$_[0]\n"; },
        );
    };
    if (my $err = $@) {
        warn "$err";
        return 0;
    }

    return 1;
}

sub activate_storage($class, $storeid, $scfg, $cache) {
    my $mountpoint = $scfg->{path};

    if (!sshfs_is_mounted($scfg)) {
        if ($scfg->{'create-base-path'} // 1) {
            make_path($mountpoint);
        }

        die "unable to activate storage '$storeid' - directory '$mountpoint' does not exist\n"
            if !-d $mountpoint;

        sshfs_mount($scfg, $storeid);
    }

    $class->SUPER::activate_storage($storeid, $scfg, $cache);
    return;
}

sub get_volume_attribute($class, $scfg, $storeid, $volname, $attribute) {
    my ($vtype) = $class->parse_volname($volname);
    return if $vtype ne 'backup';

    my $volume_path = PVE::Storage::Plugin->filesystem_path($scfg, $volname);

    if ($attribute eq 'notes') {
        my $notes_path = $volume_path . $class->SUPER::NOTES_EXT;

        if (-f $notes_path) {
            my $notes = file_get_contents($notes_path);
            return eval { decode('UTF-8', $notes, 1) } // $notes;
        }

        return "";
    }

    if ($attribute eq 'protected') {
        return -e PVE::Storage::protection_file_path($volume_path) ? 1 : 0;
    }

    return;
}

sub update_volume_attribute($class, $scfg, $storeid, $volname, $attribute, $value) {
    my ($vtype, $name) = $class->parse_volname($volname);
    die "only backups support attribute '$attribute'\n" if $vtype ne 'backup';

    my $volume_path = PVE::Storage::Plugin->filesystem_path($scfg, $volname);

    if ($attribute eq 'notes') {
        my $notes_path = $volume_path . $class->SUPER::NOTES_EXT;

        if (defined($value)) {
            my $encoded_notes = encode('UTF-8', $value);
            file_set_contents($notes_path, $encoded_notes);
        } else {
            if (!unlink $notes_path) {
                return if $! == ENOENT;
                die "could not delete notes - $!\n";
            }
        }

        return;
    }

    if ($attribute eq 'protected') {
        my $protection_path = PVE::Storage::protection_file_path($volume_path);

        # Protection already set or unset
        return if !((-e $protection_path) xor $value);

        if ($value) {
            my $fh = IO::File->new($protection_path, O_CREAT)
                or die "unable to create protection file '$protection_path' - $!\n";
            close($fh);
        } else {
            if (!unlink $protection_path) {
                return if $! == ENOENT;
                die "could not delete protection file '$protection_path' - $!\n";
            }
        }

        return;
    }

    die "attribute '$attribute' is not supported for storage type '$scfg->{type}'\n";
}

1;
