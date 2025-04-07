package PVE::BackupProvider::Plugin::DirectoryExample;

use strict;
use warnings;

use Fcntl qw(SEEK_SET);
use File::Path qw(make_path remove_tree);
use IO::File;
use IPC::Open3;
use JSON qw(from_json to_json);

use PVE::Storage::Common;
use PVE::Storage::Plugin;
use PVE::Tools qw(file_get_contents file_read_firstline file_set_contents run_command);

use base qw(PVE::BackupProvider::Plugin::Base);

# Private helpers

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

# NOTE: This is just for proof-of-concept testing! A backup provider plugin should either use the
# 'nbd' backup mechansim and use the NBD protocol or use the 'file-handle' mechanism. There should
# be no need to use /dev/nbdX nodes for proper plugins.
my sub bind_next_free_dev_nbd_node {
    my ($options) = @_;

    # /dev/nbdX devices are reserved in a file. Those reservations expires after $expiretime.
    # This avoids race conditions between allocation and use.

    die "file '/sys/module/nbd' does not exist - 'nbd' kernel module not loaded?"
	if !-e "/sys/module/nbd";

    my $line = PVE::Tools::file_read_firstline("/sys/module/nbd/parameters/nbds_max")
	or die "could not read 'nbds_max' parameter file for 'nbd' kernel module\n";
    my ($nbds_max) = ($line =~ m/(\d+)/)
	or die "could not determine 'nbds_max' parameter for 'nbd' kernel module\n";

    my $filename = "/run/qemu-server/reserved-dev-nbd-nodes";

    my $code = sub {
	my $expiretime = 60;
	my $ctime = time();

	my $used = {};
	my $latest = [0, 0];

	if (my $fh = IO::File->new ($filename, "r")) {
	    while (my $line = <$fh>) {
		if ($line =~ m/^(\d+)\s(\d+)$/) {
		    my ($n, $timestamp) = ($1, $2);

		    $latest = [$n, $timestamp] if $latest->[1] <= $timestamp;

		    if (($timestamp + $expiretime) > $ctime) {
			$used->{$n} = $timestamp; # not expired
		    }
		}
	    }
	}

	my $new_n;
	for (my $count = 0; $count < $nbds_max; $count++) {
	    my $n = ($latest->[0] + $count) % $nbds_max;
	    my $block_device = "/dev/nbd${n}";
	    next if $used->{$n}; # reserved
	    next if !-e $block_device;

	    my $st = File::stat::stat("/run/lock/qemu-nbd-nbd${n}");
	    next if defined($st) && S_ISSOCK($st->mode) && $st->uid == 0; # in use

	    # Used to avoid looping if there are other issues then the NBD node being in use
	    my $socket_error = 0;
	    eval {
		my $errfunc = sub {
		    my ($line) = @_;
		    $socket_error = 1 if $line =~ m/^qemu-nbd: Failed to set NBD socket$/;
		    log_warn($line);
		};
		run_command(["qemu-nbd", "-c", $block_device, $options->@*], errfunc => $errfunc);
	    };
	    if (my $err = $@) {
		die $err if !$socket_error;
		log_warn("unable to bind $block_device - trying next one");
		next;
	    }
	    $used->{$n} = $ctime;
	    $new_n = $n;
	    last;
	}

	my $data = "";
	$data .= "$_ $used->{$_}\n" for keys $used->%*;

	PVE::Tools::file_set_contents($filename, $data);

	return defined($new_n) ? "/dev/nbd${new_n}" : undef;
    };

    my $block_device =
	PVE::Tools::lock_file('/run/lock/qemu-server/reserved-dev-nbd-nodes.lock', 10, $code);
    die $@ if $@;

    die "unable to find free /dev/nbdX block device node\n" if !$block_device;

    return $block_device;
}

# Backup Provider API

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

    return 'dir provider example';
}

# Hooks

sub job_init {
    my ($self, $start_time) = @_;

    log_info($self, "job init called");

    if (!-e '/sys/module/nbd/parameters') {
	die "required 'nbd' kernel module not loaded - use 'modprobe nbd nbds_max=128' to load it"
	    ." manually\n";
    }

    log_info($self, "backup provider initialized successfully for new job $start_time");

    return;
}

sub job_cleanup {
    my ($self) = @_;

    log_info($self, "job cleanup called");

    return;
}

sub backup_init {
    my ($self, $vmid, $vmtype, $backup_time) = @_;

    my $archive_subdir = "${vmtype}-${backup_time}";
    my $archive = "${vmid}/${archive_subdir}";

    log_info($self, "backup start hook called");

    my $backup_dir = $self->{scfg}->{path} . "/" . $archive;

    make_path($backup_dir);
    die "unable to create directory $backup_dir\n" if !-d $backup_dir;

    $self->{$vmid}->{'backup-time'} = $backup_time;
    $self->{$vmid}->{'backup-dir'} = $backup_dir;

    $self->{$vmid}->{'archive-subdir'} = $archive_subdir;
    $self->{$vmid}->{archive} = $archive;
    return { 'archive-name' => $archive };
}

my sub get_previous_info_tainted {
    my ($self, $vmid) = @_;

    my $previous_info_file = "$self->{scfg}->{path}/$vmid/previous-info";

    return eval { from_json(file_get_contents($previous_info_file)) } // {};
}

my sub update_previous_info {
    my ($self, $vmid) = @_;

    my $previous_info_file = "$self->{scfg}->{path}/$vmid/previous-info";

    if (defined(my $info = $self->{$vmid}->{previous})) {
	file_set_contents($previous_info_file, to_json($info));
    } else {
	unlink($previous_info_file);
    }
}


sub backup_cleanup {
    my ($self, $vmid, $vmtype, $success, $info) = @_;

    if ($success) {
	log_info($self, "backup cleanup called - success");
	eval {
	    update_previous_info($self, $vmid, $self->{$vmid}->{previous});
	};
	if (my $err = $@) {
	    log_error($self, "failed to update previous-info file: $err");
	}
	my $size = 0;
	my $backup_dir = $self->{$vmid}->{'backup-dir'};
	my @backup_files = glob("$backup_dir/*");
	$size += -s $_ for @backup_files;
	my $stats = { 'archive-size' => $size };
	return { 'stats' => $stats };
    } else {
	log_info($self, "backup cleanup called - failure");

	$self->{$vmid}->{failed} = 1;

	if (my $dir = $self->{$vmid}->{'backup-dir'}) {
	    eval { remove_tree($dir) };
	    log_warning($self, "unable to clean up $dir - $@") if $@;
	}

	# Restore old previous-info so next attempt can re-use bitmap again
	if (my $info = $self->{$vmid}->{'old-previous-info'}) {
	    my $previous_info_dir = "$self->{scfg}->{path}/$vmid/";
	    my $previous_info_file = "$previous_info_dir/previous-info";
	    file_set_contents($previous_info_file, $info);
	}
    }
}

sub backup_container_prepare {
    my ($self, $vmid, $info) = @_;

    my $dir = $self->{$vmid}->{'backup-dir'};
    chown($info->{'backup-user-id'}, -1, $dir) or die "unable to change owner for $dir\n";

    return;
}

sub backup_vm_query_incremental {
    my ($self, $vmid, $volumes) = @_;

    # Try to use the last backup's disks for incremental backup if the storage
    # is configured for incremental VM backup. Need to start fresh if there is
    # no previous backup or the associated backup doesn't exist.

    return if $self->{'storage-plugin'}->get_vm_backup_mode($self->{scfg}) ne 'incremental';

    my $vmtype = 'qemu';

    my $out = {};

    my $info = get_previous_info_tainted($self, $vmid);
    for my $device_name (keys $volumes->%*) {
	$out->{$device_name} = 'new';

	my $prev_file = $info->{$device_name};
	next if !defined $prev_file;
	# it's type-time/disk.qcow2
	next if $prev_file !~ m!^([^/]+/[^/]+\.qcow2)$!;
	$prev_file = $1; # untaint

	my $full_path = "$self->{scfg}->{path}/$vmid/$prev_file";

	if (-e $full_path) {
	    $self->{$vmid}->{previous}->{$device_name} = $prev_file;
	    $out->{$device_name} = 'use';
	}
    }

    return $out;
}

sub backup_get_mechanism {
    my ($self, $vmid, $vmtype) = @_;

    return 'directory' if $vmtype eq 'lxc';
    return $self->{'storage-plugin'}->get_vm_backup_mechanism($self->{scfg}) if $vmtype eq 'qemu';

    die "unsupported guest type '$vmtype'\n";
}

sub backup_handle_log_file {
    my ($self, $vmid, $filename) = @_;

    my $log_dir = $self->{$vmid}->{'backup-dir'};
    if ($self->{$vmid}->{failed}) {
	$log_dir .= ".failed";
    }
    make_path($log_dir);
    die "unable to create directory $log_dir\n" if !-d $log_dir;

    my $data = file_get_contents($filename);
    my $target = "${log_dir}/backup.log";
    file_set_contents($target, $data);
}

my sub backup_file {
    my ($self, $vmid, $device_name, $size, $in_fh, $bitmap_mode, $next_dirty_region, $bandwidth_limit) = @_;

    # TODO honor bandwidth_limit

    my $target = "$self->{$vmid}->{'backup-dir'}/${device_name}.qcow2";

    my $create_cmd = ["qemu-img", "create", "-f", "qcow2", $target, $size];
    if (my $previous_file = $self->{$vmid}->{previous}->{$device_name}) {
	my $target_base = "../$previous_file";
	push $create_cmd->@*, "-b", $target_base, "-F", "qcow2";
    }
    run_command($create_cmd);

    my $nbd_node;
    eval {
	# allows to easily write to qcow2 target
	$nbd_node = bind_next_free_dev_nbd_node([$target, '--format=qcow2']);
	# FIXME use nbdfuse like in qemu-server rather than qemu-nbd. Seems like there is a race and
	# sysseek() can fail with "Invalid argument" if done too early...
	sleep 1;

	my $block_size = 4 * 1024 * 1024; # 4 MiB

	my $out_fh = IO::File->new($nbd_node, "r+")
	    or die "unable to open NBD backup target - $!\n";

	my $buffer = '';
	my $skip_discard;

	while (scalar((my $region_offset, my $region_length) = $next_dirty_region->())) {
	    sysseek($in_fh, $region_offset, SEEK_SET)
		// die "unable to seek '$region_offset' in NBD backup source - $!\n";
	    sysseek($out_fh, $region_offset, SEEK_SET)
		// die "unable to seek '$region_offset' in NBD backup target - $!\n";

	    my $local_offset = 0; # within the region
	    while ($local_offset < $region_length) {
		my $remaining = $region_length - $local_offset;
		my $request_size = $remaining < $block_size ? $remaining : $block_size;
		my $offset = $region_offset + $local_offset;

		my $read = sysread($in_fh, $buffer, $request_size);
		die "failed to read from backup source - $!\n" if !defined($read);
		die "premature EOF while reading backup source\n" if $read == 0;

		my $written = 0;
		while ($written < $read) {
		    my $res = syswrite($out_fh, $buffer, $request_size - $written, $written);
		    die "failed to write to backup target - $!\n" if !defined($res);
		    die "unable to progress writing to backup target\n" if $res == 0;
		    $written += $res;
		}

		if (!$skip_discard) {
		    eval { PVE::Storage::Common::deallocate($in_fh, $offset, $request_size); };
		    if (my $err = $@) {
			# Just assume that if one request didn't work, others won't either.
			log_warning(
			    $self, "discard source failed (skipping further discards) - $err");
			$skip_discard = 1;
		     }
		 }

		$local_offset += $request_size;
	    }
	}
	$out_fh->sync();
    };
    my $err = $@;

    $self->{$vmid}->{previous}->{$device_name} = "$self->{$vmid}->{'archive-subdir'}/${device_name}.qcow2";

    eval { run_command(['qemu-nbd', '-d', $nbd_node ]); };
    log_warning($self, "unable to disconnect NBD backup target - $@") if $@;

    die $err if $err;
}

my sub backup_nbd {
    my ($self, $vmid, $device_name, $size, $nbd_path, $bitmap_mode, $bitmap_name, $bandwidth_limit) = @_;

    # TODO honor bandwidth_limit

    die "need 'nbdinfo' binary from package libnbd-bin\n" if !-e "/usr/bin/nbdinfo";

    my $nbd_info_uri = "nbd+unix:///${device_name}?socket=${nbd_path}";
    my $qemu_nbd_uri = "nbd:unix:${nbd_path}:exportname=${device_name}";

    my $cpid;
    my $error_fh;
    my $next_dirty_region;

    # If there is no dirty bitmap, it can be treated as if there's a full dirty one. The output of
    # nbdinfo is a list of tuples with offset, length, type, description. The first bit of 'type' is
    # set when the bitmap is dirty, see QEMU's docs/interop/nbd.txt
    my $dirty_bitmap = [];
    if ($bitmap_mode ne 'none') {
	my $input = IO::File->new();
	my $info = IO::File->new();
	$error_fh = IO::File->new();
	my $nbdinfo_cmd = ["nbdinfo", $nbd_info_uri, "--map=qemu:dirty-bitmap:${bitmap_name}"];
	$cpid = open3($input, $info, $error_fh, $nbdinfo_cmd->@*)
	    or die "failed to spawn nbdinfo child - $!\n";

	$next_dirty_region = sub {
	    my ($offset, $length, $type);
	    do {
		my $line = <$info>;
		return if !$line;
		die "unexpected output from nbdinfo - $line\n"
		    if $line !~ m/^\s*(\d+)\s*(\d+)\s*(\d+)/; # also untaints
		($offset, $length, $type) = ($1, $2, $3);
	    } while (($type & 0x1) == 0); # not dirty
	    return ($offset, $length);
	};
    } else {
	my $done = 0;
	$next_dirty_region = sub {
	    return if $done;
	    $done = 1;
	    return (0, $size);
	};
    }

    my $nbd_node;
    eval {
	$nbd_node = bind_next_free_dev_nbd_node([$qemu_nbd_uri, "--format=raw", "--discard=on"]);

	my $in_fh = IO::File->new($nbd_node, 'r+')
	    or die "unable to open NBD backup source '$nbd_node' - $!\n";

	backup_file(
	    $self,
	    $vmid,
	    $device_name,
	    $size,
	    $in_fh,
	    $bitmap_mode,
	    $next_dirty_region,
	    $bandwidth_limit,
	);
    };
    my $err = $@;

    eval { run_command(["qemu-nbd", "-d", $nbd_node ]); };
    log_warning($self, "unable to disconnect NBD backup source - $@") if $@;

    if ($cpid) {
	my $waited;
	my $wait_limit = 5;
	for ($waited = 0; $waited < $wait_limit && waitpid($cpid, POSIX::WNOHANG) == 0; $waited++) {
	    kill 15, $cpid if $waited == 0;
	    sleep 1;
	}
	if ($waited == $wait_limit) {
	    kill 9, $cpid;
	    sleep 1;
	    log_warning($self, "unable to collect nbdinfo child process")
		if waitpid($cpid, POSIX::WNOHANG) == 0;
	}
    }

    die $err if $err;
}

my sub backup_vm_volume {
    my ($self, $vmid, $device_name, $info, $bandwidth_limit) = @_;

    my $backup_mechanism = $self->{'storage-plugin'}->get_vm_backup_mechanism($self->{scfg});

    if ($backup_mechanism eq 'nbd') {
	backup_nbd(
	    $self,
	    $vmid,
	    $device_name,
	    $info->{size},
	    $info->{'nbd-path'},
	    $info->{'bitmap-mode'},
	    $info->{'bitmap-name'},
	    $bandwidth_limit,
	);
    } elsif ($backup_mechanism eq 'file-handle') {
	backup_file(
	    $self,
	    $vmid,
	    $device_name,
	    $info->{size},
	    $info->{'file-handle'},
	    $info->{'bitmap-mode'},
	    $info->{'next-dirty-region'},
	    $bandwidth_limit,
	);
    } else {
	die "internal error - unknown VM backup mechansim '$backup_mechanism'\n";
    }
}

sub backup_vm {
    my ($self, $vmid, $guest_config, $volumes, $info) = @_;

    my $target = "$self->{$vmid}->{'backup-dir'}/guest.conf";
    file_set_contents($target, $guest_config);

    if (my $firewall_config = $info->{'firewall-config'}) {
	$target = "$self->{$vmid}->{'backup-dir'}/firewall.conf";
	file_set_contents($target, $firewall_config);
    }

    for my $device_name (sort keys $volumes->%*) {
	backup_vm_volume(
	    $self, $vmid, $device_name, $volumes->{$device_name}, $info->{'bandwidth-limit'});
    }
}

my sub backup_directory_tar {
    my ($self, $vmid, $directory, $exclude_patterns, $sources, $bandwidth_limit) = @_;

    # essentially copied from PVE/VZDump/LXC.pm' archive()

    # copied from PVE::Storage::Plugin::COMMON_TAR_FLAGS
    my @tar_flags = qw(
	--one-file-system
	-p --sparse --numeric-owner --acls
	--xattrs --xattrs-include=user.* --xattrs-include=security.capability
	--warning=no-file-ignored --warning=no-xattr-write
    );

    my $tar = ['tar', 'cpf', '-', '--totals', @tar_flags];

    push @$tar, "--directory=$directory";

    my @exclude_no_anchored = ();
    my @exclude_anchored = ();
    for my $pattern ($exclude_patterns->@*) {
	if ($pattern !~ m|^/|) {
	    push @exclude_no_anchored, $pattern;
	} else {
	    push @exclude_anchored, $pattern;
	}
    }

    push @$tar, '--no-anchored';
    push @$tar, '--exclude=lost+found';
    push @$tar, map { "--exclude=$_" } @exclude_no_anchored;

    push @$tar, '--anchored';
    push @$tar, map { "--exclude=.$_" } @exclude_anchored;

    push @$tar, $sources->@*;

    my $cmd = [ $tar ];

    push @$cmd, [ 'cstream', '-t', $bandwidth_limit * 1024 ] if $bandwidth_limit;

    my $target = "$self->{$vmid}->{'backup-dir'}/archive.tar";
    push @{$cmd->[-1]}, \(">" . PVE::Tools::shellquote($target));

    my $logfunc = sub {
	my $line = shift;
	log_info($self, "tar: $line");
    };

    PVE::Tools::run_command($cmd, logfunc => $logfunc);

    return;
};

# NOTE This only serves as an example to illustrate the 'directory' restore mechanism. It is not
# fleshed out properly, e.g. I didn't check if exclusion is compatible with
# proxmox-backup-client/rsync or xattrs/ACL/etc. work as expected!
my sub backup_directory_squashfs {
    my ($self, $vmid, $directory, $exclude_patterns, $bandwidth_limit) = @_;

    my $target = "$self->{$vmid}->{'backup-dir'}/archive.sqfs";

    my $mksquashfs = ['mksquashfs', $directory, $target, '-quiet', '-no-progress'];

    push $mksquashfs->@*, '-wildcards';

    for my $pattern ($exclude_patterns->@*) {
	if ($pattern !~ m|^/|) { # non-anchored
	    push $mksquashfs->@*, '-e', "... $pattern";
	} else { # anchored
	    push $mksquashfs->@*, '-e', substr($pattern, 1); # need to strip leading slash
	}
    }

    my $cmd = [ $mksquashfs ];

    push @$cmd, [ 'cstream', '-t', $bandwidth_limit * 1024 ] if $bandwidth_limit;

    my $logfunc = sub {
	my $line = shift;
	log_info($self, "mksquashfs: $line");
    };

    PVE::Tools::run_command($cmd, logfunc => $logfunc);

    return;
};

sub backup_container {
    my ($self, $vmid, $guest_config, $exclude_patterns, $info) = @_;

    my $target = "$self->{$vmid}->{'backup-dir'}/guest.conf";
    file_set_contents($target, $guest_config);

    if (my $firewall_config = $info->{'firewall-config'}) {
	$target = "$self->{$vmid}->{'backup-dir'}/firewall.conf";
	file_set_contents($target, $firewall_config);
    }

    my $backup_mode = $self->{'storage-plugin'}->get_lxc_backup_mode($self->{scfg});
    if ($backup_mode eq 'tar') {
	backup_directory_tar(
	    $self,
	    $vmid,
	    $info->{directory},
	    $exclude_patterns,
	    $info->{sources},
	    $info->{'bandwidth-limit'},
	);
    } elsif ($backup_mode eq 'squashfs') {
	backup_directory_squashfs(
	    $self,
	    $vmid,
	    $info->{directory},
	    $exclude_patterns,
	    $info->{'bandwidth-limit'},
	);
    } else {
	die "got unexpected backup mode '$backup_mode' from storage plugin\n";
    }
}

# Restore API

sub restore_get_mechanism {
    my ($self, $volname) = @_;

    my (undef, $relative_backup_dir) = $self->{'storage-plugin'}->parse_volname($volname);
    my ($vmtype) = $relative_backup_dir =~ m!^\d+/([a-z]+)-!;

    return ('qemu-img', $vmtype) if $vmtype eq 'qemu';

    if ($vmtype eq 'lxc') {
	my (undef, $relative_backup_dir) = $self->{'storage-plugin'}->parse_volname($volname);

	if (-e "$self->{scfg}->{path}/${relative_backup_dir}/archive.tar") {
	    $self->{'restore-mechanisms'}->{$volname} = 'tar';
	    return ('tar', $vmtype);
	}

	if (-e "$self->{scfg}->{path}/${relative_backup_dir}/archive.sqfs") {
	    $self->{'restore-mechanisms'}->{$volname} = 'directory';
	    return ('directory', $vmtype)
	}

	die "unable to find archive '$volname'\n";
    }

    die "cannot restore unexpected guest type '$vmtype'\n";
}

sub archive_get_guest_config {
    my ($self, $volname) = @_;

    my (undef, $relative_backup_dir) = $self->{'storage-plugin'}->parse_volname($volname);
    my $filename = "$self->{scfg}->{path}/${relative_backup_dir}/guest.conf";

    return file_get_contents($filename);
}

sub archive_get_firewall_config {
    my ($self, $volname) = @_;

    my (undef, $relative_backup_dir) = $self->{'storage-plugin'}->parse_volname($volname);
    my $filename = "$self->{scfg}->{path}/${relative_backup_dir}/firewall.conf";

    return if !-e $filename;

    return file_get_contents($filename);
}

sub restore_vm_init {
    my ($self, $volname) = @_;

    my $res = {};

    my (undef, $relative_backup_dir) = $self->{'storage-plugin'}->parse_volname($volname);
    my $backup_dir = "$self->{scfg}->{path}/${relative_backup_dir}";

    my @backup_files = glob("$backup_dir/*");
    for my $backup_file (@backup_files) {
	next if $backup_file !~ m!^(.*/(.*)\.qcow2)$!;
	$backup_file = $1; # untaint
	$res->{$2}->{size} = PVE::Storage::Plugin::file_size_info($backup_file, undef, 'qcow2');
    }

    return $res;
}

sub restore_vm_cleanup {
    my ($self, $volname) = @_;

    return; # nothing to do
}

sub restore_vm_volume_init {
    my ($self, $volname, $device_name, $info) = @_;

    my (undef, $relative_backup_dir) = $self->{'storage-plugin'}->parse_volname($volname);
    my $image = "$self->{scfg}->{path}/${relative_backup_dir}/${device_name}.qcow2";
    # NOTE Backing files are not allowed by Proxmox VE when restoring. The reason is that an
    # untrusted qcow2 image can specify an arbitrary backing file and thus leak data from the host.
    # For the sake of the directory example plugin, an NBD export is created, but this side-steps
    # the check and would allow the attack again. An actual implementation should check that the
    # backing file (or rather, the whole backing chain) is safe first!
    my $nbd_node = bind_next_free_dev_nbd_node([$image]);
    $self->{"${volname}/${device_name}"}->{'nbd-node'} = $nbd_node;
    return {
	'qemu-img-path' => $nbd_node,
    };
}

sub restore_vm_volume_cleanup {
    my ($self, $volname, $device_name, $info) = @_;

    if (my $nbd_node = delete($self->{"${volname}/${device_name}"}->{'nbd-node'})) {
	PVE::Tools::run_command(['qemu-nbd', '-d', $nbd_node]);
    }

    return;
}

my sub restore_tar_init {
    my ($self, $volname) = @_;

    my (undef, $relative_backup_dir) = $self->{'storage-plugin'}->parse_volname($volname);
    return { 'tar-path' => "$self->{scfg}->{path}/${relative_backup_dir}/archive.tar" };
}

my sub restore_directory_init {
    my ($self, $volname) = @_;

    my (undef, $relative_backup_dir, $vmid) = $self->{'storage-plugin'}->parse_volname($volname);
    my $archive = "$self->{scfg}->{path}/${relative_backup_dir}/archive.sqfs";

    my $mount_point = "/run/backup-provider-example/${vmid}.mount";
    make_path($mount_point);
    die "unable to create directory $mount_point\n" if !-d $mount_point;

    run_command(['mount', '-o', 'ro', $archive, $mount_point]);

    return { 'archive-directory' => $mount_point };
}

my sub restore_directory_cleanup {
    my ($self, $volname) = @_;

    my (undef, undef, $vmid) = $self->{'storage-plugin'}->parse_volname($volname);
    my $mount_point = "/run/backup-provider-example/${vmid}.mount";

    run_command(['umount', $mount_point]);

    return;
}

sub restore_container_init {
    my ($self, $volname, $info) = @_;

    if ($self->{'restore-mechanisms'}->{$volname} eq 'tar') {
	return restore_tar_init($self, $volname);
    } elsif ($self->{'restore-mechanisms'}->{$volname} eq 'directory') {
	return restore_directory_init($self, $volname);
    } else {
	die "no restore mechanism set for '$volname'\n";
    }
}

sub restore_container_cleanup {
    my ($self, $volname, $info) = @_;

    if ($self->{'restore-mechanisms'}->{$volname} eq 'tar') {
	return; # nothing to do
    } elsif ($self->{'restore-mechanisms'}->{$volname} eq 'directory') {
	return restore_directory_cleanup($self, $volname);
    } else {
	die "no restore mechanism set for '$volname'\n";
    }
}

1;
