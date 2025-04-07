package PVE::BackupProvider::Plugin::Borg;

use strict;
use warnings;

use File::chdir;
use File::Basename qw(basename);
use File::Path qw(make_path remove_tree);
use POSIX qw(strftime);

use PVE::Tools;

# ($vmtype, $vmid, $time_string)
our $ARCHIVE_RE_3 = qr!^pve-(lxc|qemu)-([0-9]+)-([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z)$!;

sub archive_name {
    my ($vmtype, $vmid, $backup_time) = @_;

    return "pve-${vmtype}-${vmid}-" . strftime("%FT%TZ", gmtime($backup_time));
}

# remove_tree can be very verbose by default, do explicit error handling and limit to one message
my sub _remove_tree {
    my ($path) = @_;

    remove_tree($path, { error => \my $err });
    if ($err && @$err) { # empty array if no error
	for my $diag (@$err) {
	    my ($file, $message) = %$diag;
	    die "cannot remove_tree '$path': $message\n" if $file eq '';
	    die "cannot remove_tree '$path': unlinking $file failed - $message\n";
	}
    }
}

my sub prepare_run_dir {
    my ($storeid, $archive, $operation, $uid) = @_;

    my $run_dir = "/run/pve-storage/borg-plugin/${storeid}.${archive}.${operation}.$$";
    _remove_tree($run_dir);
    make_path($run_dir) or die "unable to create directory $run_dir\n";
    chmod(0700, $run_dir) or die "unable to chmod directory $run_dir - $!\n";
    if ($uid) {
	chown($uid, -1, $run_dir) or die "unable to change owner for $run_dir\n";
    }

    return $run_dir;
}

my sub log_info {
    my ($self, $message) = @_;

    $self->{'log-function'}->('info', $message);
}

my sub log_warning {
    my ($self, $message) = @_;

    $self->{'log-function'}->('warn', $message);
}

my sub log_error {
    my ($self, $message) = @_;

    $self->{'log-function'}->('err', $message);
}

my sub file_contents_from_archive {
    my ($self, $archive, $file) = @_;

    return $self->{'storage-plugin'}->borg_cmd_extract_contents(
	$self->{scfg},
	$self->{storeid},
	$archive,
	[$file],
    );
}

# Plugin implementation

sub new {
    my ($class, $storage_plugin, $scfg, $storeid, $log_function) = @_;

    my $self = bless {
	scfg => $scfg,
	storeid => $storeid,
	'storage-plugin' => $storage_plugin,
	'log-function' => $log_function,
    }, $class;

    return $self;
}

sub provider_name {
    my ($self) = @_;

    return "Borg";
}

sub job_init {
    my ($self, $start_time) = @_;

    $self->{'job-id'} = $start_time;
    $self->{password} = $self->{'storage-plugin'}->borg_get_password(
	$self->{scfg}, $self->{storeid});
    $self->{'ssh-key-fh'} = $self->{'storage-plugin'}->borg_open_ssh_key(
	$self->{scfg}, $self->{storeid});
}

sub job_cleanup {
    my ($self) = @_;

    delete($self->{password});
    close($self->{'ssh-key-fh'});

    return;
}

sub backup_init {
    my ($self, $vmid, $vmtype, $start_time) = @_;

    $self->{$vmid}->{archive} = archive_name($vmtype, $vmid, $start_time);

    return { 'archive-name' => $self->{$vmid}->{archive} };
}

sub backup_cleanup {
    my ($self, $vmid, $vmtype, $success, $info) = @_;

    if (defined($vmtype) && $vmtype eq 'lxc') {
	if (my $run_dir = $self->{$vmid}->{'run-dir'}) {
	    eval {
		# tmpfs for temporary SSH files gets mounted there in backup_container()
		eval { PVE::Tools::run_command(['umount', "${run_dir}/ssh"]); };
		eval { PVE::Tools::run_command(['umount', '-R', "${run_dir}/backup/filesystem"]); };
		_remove_tree($run_dir);
	    };
	    die "unable to clean up $run_dir - $@" if $@;
	}
    }
    return { stats => { 'archive-size' => 0 } }; # TODO get size
}

sub backup_container_prepare {
    my ($self, $vmid, $info) = @_;

    my $archive = $self->{$vmid}->{archive};
    my $run_dir = prepare_run_dir(
	$self->{storeid}, $archive, "backup-container", $info->{'backup-user-id'});
    $self->{$vmid}->{'run-dir'} = $run_dir;

    my $create_dir = sub {
	my $dir = shift;
	make_path($dir) or die "unable to create directory $dir\n";
	chmod(0700, $dir) or die "unable to chmod directory $dir\n";
	chown($info->{'backup-user-id'}, -1, $dir)
	    or die "unable to change owner for $dir\n";
    };

    $create_dir->("${run_dir}/backup/");
    $create_dir->("${run_dir}/backup/filesystem");
    $create_dir->("${run_dir}/ssh");
    $create_dir->("${run_dir}/.config");
    $create_dir->("${run_dir}/.cache");

    for my $subdir ($info->{sources}->@*) {
	PVE::Tools::run_command([
	    'mount',
	    '-o', 'bind,ro',
	    "$info->{directory}/${subdir}",
	    "${run_dir}/backup/filesystem/${subdir}",
	]);
    }
}

sub backup_get_mechanism {
    my ($self, $vmid, $vmtype) = @_;

    return 'file-handle' if $vmtype eq 'qemu';
    return 'directory' if $vmtype eq 'lxc';

    die "unsupported VM type '$vmtype'\n";
}

sub backup_handle_log_file {
    my ($self, $vmid, $filename) = @_;

    return; # don't upload, Proxmox VE keeps the task log too
}

sub backup_vm_query_incremental {
    my ($self, $vmid, $volumes) = @_;

    return; # no support currently
}

my sub backup_vm_setup_loopdev {
    my ($file) = @_;

    my $device;
    my $parser = sub {
	my $line = shift;
	if ($line =~ m@^(/dev/loop\d+)$@) {
	    $device = $1;
	}
    };
    my $losetup_cmd = [
	'losetup',
	'--show',
	'-r',
	'-f',
	$file,
    ];
    PVE::Tools::run_command($losetup_cmd, outfunc => $parser);
    return $device;
}

sub backup_vm {
    my ($self, $vmid, $guest_config, $volumes, $info) = @_;

    # TODO honor bandwith limit
    # TODO discard?

    my $archive = $self->{$vmid}->{archive};

    my $run_dir = prepare_run_dir($self->{storeid}, $archive, "backup-vm");
    my $volume_dir = "${run_dir}/volumes";
    make_path($volume_dir) or die "unable to create directory $volume_dir\n";

    PVE::Tools::file_set_contents("${run_dir}/guest.config", $guest_config);
    my $paths = ['./guest.config'];

    if (my $firewall_config = $info->{'firewall-config'}) {
	PVE::Tools::file_set_contents("${run_dir}/firewall.config", $firewall_config);
	push $paths->@*, './firewall.config';
    }

    my @blockdevs = ();

    # TODO --stats for size?

    eval {
	for my $device_name (sort keys $volumes->%*) {
	    # FIXME there is no option to follow symlinks except in combination with special files,
	    # so loop devices are set up here for this purpose. Newer versions of Borg (since 1.4)
	    # could use the slashdot hack instead:
	    # https://github.com/borgbackup/borg/commit/e7bd18d7f38ddf9e58a4587ae4a2ad8a24d67374
	    my $path = "/proc/$$/fd/" . fileno($volumes->{$device_name}->{'file-handle'});
	    my $blockdev = backup_vm_setup_loopdev($path);
	    push @blockdevs, $blockdev;

	    my $link_name = "${volume_dir}/${device_name}.raw";
	    symlink($blockdev, $link_name) or die "could not create symlink $link_name -> $blockdev\n";
	    push $paths->@*, "./volumes/" . basename($link_name, ());
	}

	local $CWD = $run_dir;

	$self->{'storage-plugin'}->borg_cmd_create(
	    $self->{scfg},
	    $self->{storeid},
	    $self->{$vmid}->{archive},
	    $paths,
	    ['--read-special', '--progress'],
	);
    };
    my $err = $@;
    for my $blockdev (@blockdevs) {
	eval { PVE::Tools::run_command(['losetup', '-d', $blockdev]); };
	log_warning($self, "cannot cleanup loop device - $@") if $@;
    }
    eval { _remove_tree($run_dir) };
    log_warning($self, $@) if $@;
    die $err if $err;
}

sub backup_container {
    my ($self, $vmid, $guest_config, $exclude_patterns, $info) = @_;

    # TODO honor bandwith limit

    my $run_dir = $self->{$vmid}->{'run-dir'};
    my $backup_dir = "${run_dir}/backup";

    my $archive = $self->{$vmid}->{archive};

    my $ssh_key;
    if ($self->{'ssh-key-fh'}) {
	$ssh_key =
	    PVE::Tools::safe_read_from($self->{'ssh-key-fh'}, 1024 * 1024, 0, "SSH key file");
    }

    my (undef, $ssh_options) =
	$self->{'storage-plugin'}->borg_setup_ssh_dir($self->{scfg}, "${run_dir}/ssh", $ssh_key);

    PVE::Tools::file_set_contents("${backup_dir}/guest.config", $guest_config);
    my $paths = ['./guest.config'];

    if (my $firewall_config = $info->{'firewall-config'}) {
	PVE::Tools::file_set_contents("${backup_dir}/firewall.config", $firewall_config);
	push $paths->@*, './firewall.config';
    }

    push $paths->@*, "./filesystem";

    my $opts = ['--numeric-ids', '--sparse', '--progress'];

    for my $pattern ($exclude_patterns->@*) {
	if ($pattern =~ m|^/|) {
	    push $opts->@*, '-e', "filesystem${pattern}";
	} else {
	    push $opts->@*, '-e', "filesystem/**${pattern}";
	}
    }

    push $opts->@*, '-e', "filesystem/**lost+found" if $info->{'backup-user-id'} != 0;

    # TODO --stats for size?

    # Don't make it local to avoid permission denied error when changing back, because the method is
    # executed in a user namespace.
    $CWD = $backup_dir if $info->{'backup-user-id'} != 0;
    {
	local $CWD = $backup_dir;
	local $ENV{BORG_BASE_DIR} = ${run_dir};
	local $ENV{BORG_PASSPHRASE} = $self->{password};

	local $ENV{BORG_RSH} = "ssh " . join(" ", $ssh_options->@*);

	my $uri = $self->{'storage-plugin'}->borg_repository_uri($self->{scfg}, $self->{storeid});
	my $archive = $self->{$vmid}->{archive};

	my $cmd = ['borg', 'create', $opts->@*, "${uri}::${archive}", $paths->@*];

	PVE::Tools::run_command($cmd, errmsg => "command @$cmd failed");
    }
}

sub restore_get_mechanism {
    my ($self, $volname) = @_;

    my (undef, $archive) = $self->{'storage-plugin'}->parse_volname($volname);
    my ($vmtype) = $archive =~ m!^pve-([^\s-]+)!
	or die "cannot parse guest type from archive name '$archive'\n";

    return ('qemu-img', $vmtype) if $vmtype eq 'qemu';
    return ('directory', $vmtype) if $vmtype eq 'lxc';

    die "unexpected guest type '$vmtype'\n";
}

sub archive_get_guest_config {
    my ($self, $volname) = @_;

    my (undef, $archive) = $self->{'storage-plugin'}->parse_volname($volname);
    return file_contents_from_archive($self, $archive, 'guest.config');
}

sub archive_get_firewall_config {
    my ($self, $volname) = @_;

    my (undef, $archive) = $self->{'storage-plugin'}->parse_volname($volname);
    my $config = eval {
	file_contents_from_archive($self, $archive, 'firewall.config');
    };
    if (my $err = $@) {
	return if $err =~ m!Include pattern 'firewall\.config' never matched\.!;
	die $err;
    }
    return $config;
}

sub restore_vm_init {
    my ($self, $volname) = @_;

    my $res = {};

    my (undef, $archive, $vmid) = $self->{'storage-plugin'}->parse_volname($volname);

    my $run_dir = prepare_run_dir($self->{storeid}, $archive, "restore-vm");
    $self->{$volname}->{'run-dir'} = $run_dir;

    my $mount_point = "${run_dir}/mount";
    make_path($mount_point) or die "unable to create directory $mount_point\n";
    $self->{$volname}->{'mount-point'} = $mount_point;

    $self->{'storage-plugin'}->borg_cmd_mount(
	$self->{scfg},
	$self->{storeid},
	$archive,
	$mount_point,
    );

    my @backup_files = glob("$mount_point/volumes/*");
    for my $backup_file (@backup_files) {
	next if $backup_file !~ m!^(.*/(.*)\.raw)$!; # untaint
	($backup_file, my $device_name) = ($1, $2);
	# TODO avoid dependency on base plugin?
	$res->{$device_name}->{size} =
	    PVE::Storage::Plugin::file_size_info($backup_file, undef, 'raw');
    }

    return $res;
}

sub restore_vm_cleanup {
    my ($self, $volname) = @_;

    my $run_dir = $self->{$volname}->{'run-dir'} or return;
    my $mount_point = $self->{$volname}->{'mount-point'};

    eval { PVE::Tools::run_command(['umount', $mount_point]) };
    eval { _remove_tree($run_dir); };
    die "unable to clean up $run_dir - $@" if $@;

    return;
}

sub restore_vm_volume_init {
    my ($self, $volname, $device_name, $info) = @_;

    my $mount_point = $self->{$volname}->{'mount-point'}
	or die "expected mount point for archive not present\n";

    return { 'qemu-img-path' => "${mount_point}/volumes/${device_name}.raw" };
}

sub restore_vm_volume_cleanup {
    my ($self, $volname, $device_name, $info) = @_;

    return;
}

sub restore_container_init {
    my ($self, $volname, $info) = @_;

    my (undef, $archive, $vmid) = $self->{'storage-plugin'}->parse_volname($volname);
    my $run_dir = prepare_run_dir($self->{storeid}, $archive, "restore-container");
    $self->{$volname}->{'run-dir'} = $run_dir;

    my $mount_point = "${run_dir}/mount";
    make_path($mount_point) or die "unable to create directory $mount_point\n";
    $self->{$volname}->{'mount-point'} = $mount_point;

    $self->{'storage-plugin'}->borg_cmd_mount(
	$self->{scfg},
	$self->{storeid},
	$archive,
	$mount_point,
    );

    return { 'archive-directory' => "${mount_point}/filesystem" };
}

sub restore_container_cleanup {
    my ($self, $volname, $info) = @_;

    my $run_dir = $self->{$volname}->{'run-dir'} or return;
    my $mount_point = $self->{$volname}->{'mount-point'};

    eval { PVE::Tools::run_command(['umount', $mount_point]) };
    eval { _remove_tree($run_dir); };
    die "unable to clean up $run_dir - $@" if $@;
}

1;
