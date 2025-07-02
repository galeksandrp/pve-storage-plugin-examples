package PVE::Storage::Custom::BackupProviderDirExamplePlugin;

use strict;
use warnings;

use File::Basename qw(basename);

use PVE::BackupProvider::Plugin::DirectoryExample;
use PVE::Tools;

use base qw(PVE::Storage::Plugin);

# Helpers

sub get_vm_backup_mechanism {
    my ($class, $scfg) = @_;

    return $scfg->{'vm-backup-mechanism'} // properties()->{'vm-backup-mechanism'}->{'default'};
}

sub get_vm_backup_mode {
    my ($class, $scfg) = @_;

    return $scfg->{'vm-backup-mode'} // properties()->{'vm-backup-mode'}->{'default'};
}

sub get_lxc_backup_mode {
    my ($class, $scfg) = @_;

    return $scfg->{'lxc-backup-mode'} // properties()->{'lxc-backup-mode'}->{'default'};
}

# Configuration

sub api {
    return 11;
}

sub type {
    return 'backup-provider-dir-example';
}

sub plugindata {
    return {
	content => [ { backup => 1, none => 1 }, { backup => 1 } ],
	features => { 'backup-provider' => 1 },
	'sensitive-properties' => {},
    };
}

sub properties {
    return {
	'lxc-backup-mode' => {
	    description => "How to create LXC backups. tar - create a tar archive."
		." squashfs - create a squashfs image. Requires squashfs-tools to be installed.",
	    type => 'string',
	    enum => [qw(tar squashfs)],
	    default => 'tar',
	},
	'vm-backup-mechanism' => {
	    description => "Which mechanism to use for creating VM backups. nbd - access data via "
		." NBD export. file-handle - access data via file handle.",
	    type => 'string',
	    enum => [qw(nbd file-handle)],
	    default => 'file-handle',
	},
	'vm-backup-mode' => {
	    description => "How to create VM backups. full - always create full backups."
		." incremental - create incremental backups when possible, fallback to full when"
		." necessary, e.g. VM disk's bitmap is invalid.",
	    type => 'string',
	    enum => [qw(full incremental)],
	    default => 'full',
	},
    };
}

sub options {
    return {
	path => { fixed => 1 },
	'lxc-backup-mode' => { optional => 1 },
	'vm-backup-mechanism' => { optional => 1 },
	'vm-backup-mode' => { optional => 1 },
	disable => { optional => 1 },
	nodes => { optional => 1 },
	'prune-backups' => { optional => 1 },
	'max-protected-backups' => { optional => 1 },
    };
}

# Storage implementation

# NOTE a proper backup storage should implement this
sub prune_backups {
    my ($class, $scfg, $storeid, $keep, $vmid, $type, $dryrun, $logfunc) = @_;

    die "not implemented";
}

sub parse_volname {
    my ($class, $volname) = @_;

    if ($volname =~ m!^backup/((\d+)/[a-z]+-\d+)$!) {
	my ($filename, $vmid) = ($1, $2);
	return ('backup', $filename, $vmid);
    }

    die "unable to parse volume name '$volname'\n";
}

sub path {
    my ($class, $scfg, $volname, $storeid, $snapname) = @_;

    die "volume snapshot is not possible on backup-provider-dir-example volume" if $snapname;

    my ($type, $filename, $vmid) = $class->parse_volname($volname);

    return ("$scfg->{path}/${filename}", $vmid, $type);
}

sub create_base {
    my ($class, $storeid, $scfg, $volname) = @_;

    die "cannot create base image in backup-provider-dir-example storage\n";
}

sub clone_image {
    my ($class, $scfg, $storeid, $volname, $vmid, $snap) = @_;

    die "can't clone images in backup-provider-dir-example storage\n";
}

sub alloc_image {
    my ($class, $storeid, $scfg, $vmid, $fmt, $name, $size) = @_;

    die "can't allocate space in backup-provider-dir-example storage\n";
}

# NOTE a proper backup storage should implement this
sub free_image {
    my ($class, $storeid, $scfg, $volname, $isBase) = @_;

    # if it's a backing file, it would need to be merged into the upper image first.

    die "not implemented";
}

sub list_images {
    my ($class, $storeid, $scfg, $vmid, $vollist, $cache) = @_;

    my $res = [];

    return $res;
}

sub list_volumes {
    my ($class, $storeid, $scfg, $vmid, $content_types) = @_;

    my $path = $scfg->{path};

    my $res = [];
    for my $type ($content_types->@*) {
	next if $type ne 'backup';

	my @guest_dirs = glob("$path/*");
	for my $guest_dir (@guest_dirs) {
	    next if !-d $guest_dir || $guest_dir !~ m!/(\d+)$!;

	    my $backup_vmid = basename($guest_dir);

	    next if defined($vmid) && $backup_vmid != $vmid;

	    my @backup_dirs = glob("$guest_dir/*");
	    for my $backup_dir (@backup_dirs) {
		next if !-d $backup_dir || $backup_dir !~ m!/(lxc|qemu)-(\d+)$!;
		my ($subtype, $backup_id) = ($1, $2);

		my $size = 0;
		my @backup_files = glob("$backup_dir/*");
		$size += -s $_ for @backup_files;

		push $res->@*, {
		    volid => "$storeid:backup/${backup_vmid}/${subtype}-${backup_id}",
		    vmid => $backup_vmid,
		    format => "directory",
		    ctime => $backup_id,
		    size => $size,
		    subtype => $subtype,
		    content => $type,
		    # TODO parent for incremental
		};
	    }
	}
    }

    return $res;
}

sub activate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;

    my $path = $scfg->{path};

    my $timeout = 2;
    if (!PVE::Tools::run_fork_with_timeout($timeout, sub {-d $path})) {
	die "unable to activate storage '$storeid' - directory '$path' does not exist or is"
	    ." unreachable\n";
    }

    return 1;
}

sub deactivate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;

    return 1;
}

sub activate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = @_;

    die "volume snapshot is not possible on backup-provider-dir-example volume" if $snapname;

    return 1;
}

sub deactivate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = @_;

    die "volume snapshot is not possible on backup-provider-dir-example volume" if $snapname;

    return 1;
}

sub get_volume_attribute {
    my ($class, $scfg, $storeid, $volname, $attribute) = @_;

    return;
}

# NOTE a proper backup storage should implement this to support backup notes and
# setting protected status.
sub update_volume_attribute {
    my ($class, $scfg, $storeid, $volname, $attribute, $value) = @_;

    die "attribute '$attribute' is not supported on backup-provider-dir-example volume";
}

sub volume_size_info {
    my ($class, $scfg, $storeid, $volname, $timeout) = @_;

    my (undef, $relative_backup_dir) = $class->parse_volname($volname);
    my ($ctime) = $relative_backup_dir =~ m/-(\d+)$/;
    my $backup_dir = "$scfg->{path}/${relative_backup_dir}";

    my $size = 0;
    my @backup_files = glob("$backup_dir/*");
    for my $backup_file (@backup_files) {
	if ($backup_file =~ m!\.qcow2$!) {
	    $size += PVE::Storage::Plugin::file_size_info($backup_file, undef, 'qcow2');
	} else {
	    $size += -s $backup_file;
	}
    }

    my $parent; # TODO for incremental

    return wantarray ? ($size, 'directory', $size, $parent, $ctime) : $size;
}

sub volume_resize {
    my ($class, $scfg, $storeid, $volname, $size, $running) = @_;

    die "volume resize is not possible on backup-provider-dir-example volume";
}

sub volume_snapshot {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;

    die "volume snapshot is not possible on backup-provider-dir-example volume";
}

sub volume_snapshot_rollback {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;

    die "volume snapshot rollback is not possible on backup-provider-dir-example volume";
}

sub volume_snapshot_delete {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;

    die "volume snapshot delete is not possible on backup-provider-dir-example volume";
}

sub volume_has_feature {
    my ($class, $scfg, $feature, $storeid, $volname, $snapname, $running) = @_;

    return 0;
}

sub new_backup_provider {
    my ($class, $scfg, $storeid, $bandwidth_limit, $log_function) = @_;

    return PVE::BackupProvider::Plugin::DirectoryExample->new(
	$class, $scfg, $storeid, $bandwidth_limit, $log_function);
}

1;
