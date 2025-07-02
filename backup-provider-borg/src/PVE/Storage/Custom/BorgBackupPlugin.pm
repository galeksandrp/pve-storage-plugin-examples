package PVE::Storage::Custom::BorgBackupPlugin;

use strict;
use warnings;

use Fcntl qw(F_GETFD F_SETFD FD_CLOEXEC);
use File::Path qw(make_path remove_tree);
use JSON qw(from_json);
use MIME::Base64 qw(decode_base64 encode_base64);
use Net::IP;
use POSIX qw(ENOENT);

use PVE::Storage;
use PVE::Tools;

use PVE::BackupProvider::Plugin::Borg;

use base qw(PVE::Storage::Plugin);

sub api {
    return 11;
}

sub check_config {
    my ($class, $sectionId, $config, $create, $skipSchemaCheck) = @_;

    if (my $ssh_public_keys = $config->{'ssh-server-public-keys'}) {
	if ($ssh_public_keys !~ m/^[A-Za-z0-9+\/]+={0,2}$/) {
	    $config->{'ssh-server-public-keys'} = encode_base64($ssh_public_keys, '');
	}
    }

    return $class->SUPER::check_config($sectionId, $config, $create, $skipSchemaCheck);
}

sub borg_repository_uri {
    my ($class, $scfg, $storeid) = @_;

    my $uri = '';
    my $server = $scfg->{server} or die "no server configured for $storeid\n";
    my $username = $scfg->{username} or die "no username configured for $storeid\n";
    my $prefix = "ssh://$username@";
    $server = "[$server]" if Net::IP::ip_is_ipv6($server);
    if (my $port = $scfg->{port}) {
	$uri = "${prefix}${server}:${port}";
    } else {
	$uri = "${prefix}${server}";
    }
    $uri .= $scfg->{'repository-path'};

    return $uri;
}

my sub borg_password_file_name {
    my ($scfg, $storeid) = @_;

    return "/etc/pve/priv/storage/${storeid}.pw";
}

my sub borg_set_password {
    my ($scfg, $storeid, $password) = @_;

    my $pwfile = borg_password_file_name($scfg, $storeid);
    mkdir "/etc/pve/priv/storage";

    PVE::Tools::file_set_contents($pwfile, "$password\n");
}

my sub borg_delete_password {
    my ($scfg, $storeid) = @_;

    my $pwfile = borg_password_file_name($scfg, $storeid);

    unlink $pwfile;
}

sub borg_get_password {
    my ($class, $scfg, $storeid) = @_;

    my $pwfile = borg_password_file_name($scfg, $storeid);

    return PVE::Tools::file_read_firstline($pwfile);
}

sub borg_setup_ssh_dir {
    my ($class, $scfg, $ssh_dir, $ssh_key) = @_;

    my $dir_created;
    my $ssh_opts = [];

    my $ensure_dir_created = sub {
	return if $dir_created;
	# for container backup, it needs to be created while privileged and already exists
	if (!-d $ssh_dir) {
	    make_path($ssh_dir) or die "unable to create directory $ssh_dir\n";
	    chmod(0700, $ssh_dir) or die "unable to chmod directory $ssh_dir\n";
	}
	PVE::Tools::run_command(
	    ['mount', '-t', 'tmpfs', '-o', 'size=1M,mode=0700', 'tmpfs', $ssh_dir]);
	$dir_created = 1;
    };

    if ($ssh_key) {
	$ensure_dir_created->();
	PVE::Tools::file_set_contents("${ssh_dir}/ssh.key", $ssh_key, 0600);
	push $ssh_opts->@*, '-i', "${ssh_dir}/ssh.key";
    }

    if ($scfg->{'ssh-server-public-keys'}) {
	$ensure_dir_created->();
	my $raw = decode_base64($scfg->{'ssh-server-public-keys'});
	PVE::Tools::file_set_contents("${ssh_dir}/known_hosts", $raw, 0600);
	push $ssh_opts->@*, '-o', "UserKnownHostsFile=${ssh_dir}/known_hosts";
	push $ssh_opts->@*, '-o', "GlobalKnownHostsFile=none";
    }

    return ($dir_created, $ssh_opts);
}

sub borg_cmd_env {
    my ($class, $scfg, $storeid, $sub) = @_;

    my $ssh_dir = "/run/pve-storage/borg-plugin/${storeid}.ssh.$$";
    my $ssh_key = borg_get_ssh_key($scfg, $storeid);
    my ($uses_ssh_dir, $ssh_options) = $class->borg_setup_ssh_dir($scfg, $ssh_dir, $ssh_key);
    local $ENV{BORG_RSH} = "ssh " . join(" ", $ssh_options->@*);

    local $ENV{BORG_PASSPHRASE} = $class->borg_get_password($scfg, $storeid);

    my $res = eval {
	my $uri = $class->borg_repository_uri($scfg, $storeid);
	return $sub->($uri);
    };
    my $err = $@;

    if ($uses_ssh_dir) {
	eval { PVE::Tools::run_command(['umount', "$ssh_dir"]); };
	warn "unable to unmount directory $ssh_dir - $@" if $@;
	eval { remove_tree($ssh_dir); };
	warn "unable to cleanup directory $ssh_dir - $@" if $@;
    }

    die $err if $err;

    return $res;
}

sub borg_cmd_list {
    my ($class, $scfg, $storeid) = @_;

    return $class->borg_cmd_env($scfg, $storeid, sub {
	my ($uri) = @_;

	my $json = '';
	my $cmd = ['borg', 'list', '--json', $uri];

	my $errfunc = sub { warn $_[0]; };
	my $outfunc = sub { $json .= $_[0]; };

	PVE::Tools::run_command(
	    $cmd, errmsg => "command @$cmd failed", outfunc => $outfunc, errfunc => $errfunc);

	my $res = eval { from_json($json) };
	die "unable to parse 'borg list' output - $@\n" if $@;
	return $res;
    });
}

sub borg_cmd_create {
    my ($class, $scfg, $storeid, $archive, $paths, $opts) = @_;

    return $class->borg_cmd_env($scfg, $storeid, sub {
	my ($uri) = @_;

	my $cmd = ['borg', 'create', $opts->@*, "${uri}::${archive}", $paths->@*];

	PVE::Tools::run_command($cmd, errmsg => "command @$cmd failed");

	return;
    });
}

sub borg_cmd_extract_contents {
    my ($class, $scfg, $storeid, $archive, $paths) = @_;

    return $class->borg_cmd_env($scfg, $storeid, sub {
	my ($uri) = @_;

	my $output = '';
	my $outfunc = sub {
	    $output .= "$_[0]\n";
	};

	my $cmd = ['borg', 'extract', '--stdout', "${uri}::${archive}", $paths->@*];

	PVE::Tools::run_command($cmd, errmsg => "command @$cmd failed", outfunc => $outfunc);

	return $output;
    });
}

sub borg_cmd_delete {
    my ($class, $scfg, $storeid, $archive) = @_;

    return $class->borg_cmd_env($scfg, $storeid, sub {
	my ($uri) = @_;

	my $cmd = ['borg', 'delete', "${uri}::${archive}"];

	PVE::Tools::run_command($cmd, errmsg => "command @$cmd failed");

	return;
    });
}

sub borg_cmd_info {
    my ($class, $scfg, $storeid, $archive, $timeout) = @_;

    return $class->borg_cmd_env($scfg, $storeid, sub {
	my ($uri) = @_;

	my $json = '';
	my $cmd = ['borg', 'info', '--json', "${uri}::${archive}"];

	my $errfunc = sub { warn $_[0]; };
	my $outfunc = sub { $json .= $_[0]; };

	PVE::Tools::run_command(
	    $cmd,
	    errmsg => "command @$cmd failed",
	    timeout => $timeout,
	    outfunc => $outfunc,
	    errfunc => $errfunc,
	);

	my $res = eval { from_json($json) };
	die "unable to parse 'borg info' output for archive '$archive' - $@\n" if $@;
	return $res;
    });
}

sub borg_cmd_mount {
    my ($class, $scfg, $storeid, $archive, $mount_point) = @_;

    return $class->borg_cmd_env($scfg, $storeid, sub {
	my ($uri) = @_;

	my $cmd = ['borg', 'mount', "${uri}::${archive}", $mount_point];

	PVE::Tools::run_command($cmd, errmsg => "command @$cmd failed");

	return;
    });
}

my sub parse_backup_time {
    my ($time_string) = @_;

    my @tm = (POSIX::strptime($time_string, "%FT%TZ"));
    # expect sec, min, hour, mday, mon, year
    if (grep { !defined($_) } @tm[0..5]) {
	warn "error parsing time from string '$time_string'\n";
	return 0;
    } else {
	local $ENV{TZ} = 'UTC'; # time string is UTC

	# Fill in isdst to avoid undef warning. No daylight saving time for UTC.
	$tm[8] //= 0;

	if (my $since_epoch = mktime(@tm)) {
	    return int($since_epoch);
	} else {
	    warn "error parsing time from string '$time_string'\n";
	    return 0;
	}
    }
}

# Helpers

sub type {
    return 'borg';
}

sub plugindata {
    return {
	content => [ { backup => 1, none => 1 }, { backup => 1 } ],
	features => { 'backup-provider' => 1 },
	'sensitive-properties' => {
	    password => 1,
	    'ssh-private-key' => 1,
	},
    };
}

sub properties {
    return {
	'repository-path' => {
	    description => "Path to the backup repository",
	    type => 'string',
	},
	'ssh-private-key' => {
	    # Since 1 is written to the config when the key is present, the format is not checked.
	    description => "SSH identity/private key for the client-side in PEM format.",
	    type => 'string',
	},
	'ssh-server-public-keys' => {
	    description => "SSH public key(s) for the server-side, (one key per line, OpenSSH"
		." format).",
	    type => 'string',
	},
    };
}

sub options {
    return {
	'repository-path' => { fixed => 1 },
	server => { fixed => 1 },
	port => { optional => 1 },
	username => { fixed => 1 },
	'ssh-private-key' => { optional => 1 },
	'ssh-server-public-keys' => { optional => 1 },
	password => { optional => 1 },
	disable => { optional => 1 },
	nodes => { optional => 1 },
	'prune-backups' => { optional => 1 },
	'max-protected-backups' => { optional => 1 },
    };
}

sub borg_ssh_key_file_name {
    my ($scfg, $storeid) = @_;

    return "/etc/pve/priv/storage/${storeid}.ssh.key";
}

sub borg_set_ssh_key {
    my ($scfg, $storeid, $key) = @_;

    my $keyfile = borg_ssh_key_file_name($scfg, $storeid);
    mkdir "/etc/pve/priv/storage";

    PVE::Tools::file_set_contents($keyfile, "$key\n");
}

sub borg_delete_ssh_key {
    my ($scfg, $storeid) = @_;

    my $keyfile = borg_ssh_key_file_name($scfg, $storeid);

    if (!unlink $keyfile) {
	return if $! == ENOENT;
	die "failed to delete SSH key! $!\n";
    }
    delete $scfg->{'ssh-private-key'};
}

sub borg_get_ssh_key {
    my ($scfg, $storeid) = @_;

    my $keyfile = borg_ssh_key_file_name($scfg, $storeid);

    return if !-f $keyfile;

    return PVE::Tools::file_get_contents($keyfile);
}

# Returns a file handle with FD_CLOEXEC disabled if there is an SSH key , or `undef` if there is
# not. Dies on error.
sub borg_open_ssh_key {
    my ($self, $scfg, $storeid) = @_;

    my $ssh_key_file = borg_ssh_key_file_name($scfg, $storeid);

    my $keyfd;
    if (!open($keyfd, '<', $ssh_key_file)) {
	if ($! == ENOENT) {
	    die "SSH key configured but no key file found!\n" if $scfg->{'ssh-private-key'};
	    return undef;
	}
	die "failed to open SSH key: $ssh_key_file: $!\n";
    }
    my $flags = fcntl($keyfd, F_GETFD, 0)
	// die "failed to get file descriptor flags for SSH key FD: $!\n";
    fcntl($keyfd, F_SETFD, $flags & ~FD_CLOEXEC)
	or die "failed to remove FD_CLOEXEC from SSH key file descriptor\n";

    return $keyfd;
}

# Storage implementation

sub on_add_hook {
    my ($class, $storeid, $scfg, %param) = @_;

    if (defined(my $password = $param{password})) {
	borg_set_password($scfg, $storeid, $password);
    } else {
	borg_delete_password($scfg, $storeid);
    }

    if (defined(my $ssh_key = delete $param{'ssh-private-key'})) {
	borg_set_ssh_key($scfg, $storeid, $ssh_key);
	$scfg->{'ssh-private-key'} = 1;
    } else {
	borg_delete_ssh_key($scfg, $storeid);
    }

    if ($scfg->{'ssh-server-public-keys'}) {
	my $ssh_public_keys = decode_base64($scfg->{'ssh-server-public-keys'});
	PVE::Tools::validate_ssh_public_keys($ssh_public_keys);
    }

    return;
}

sub on_update_hook {
    my ($class, $storeid, $scfg, %param) = @_;

    if (exists($param{password})) {
	if (defined($param{password})) {
	    borg_set_password($scfg, $storeid, $param{password});
	} else {
	    borg_delete_password($scfg, $storeid);
	}
    }

    if (exists($param{'ssh-private-key'})) {
	if (defined(my $ssh_key = delete($param{'ssh-private-key'}))) {
	    borg_set_ssh_key($scfg, $storeid, $ssh_key);
	    $scfg->{'ssh-private-key'} = 1;
	} else {
	    borg_delete_ssh_key($scfg, $storeid);
	}
    }

    if ($scfg->{'ssh-server-public-keys'}) {
	my $ssh_public_keys = decode_base64($scfg->{'ssh-server-public-keys'});
	PVE::Tools::validate_ssh_public_keys($ssh_public_keys);
    }

    return;
}

sub on_delete_hook {
    my ($class, $storeid, $scfg) = @_;

    borg_delete_password($scfg, $storeid);
    borg_delete_ssh_key($scfg, $storeid);

    return;
}

sub prune_backups {
    my ($class, $scfg, $storeid, $keep, $vmid, $type, $dryrun, $logfunc) = @_;

    # FIXME - is 'borg prune' compatible with ours?
    die "not implemented";
}

sub parse_volname {
    my ($class, $volname) = @_;

    if ($volname =~ m!^backup/(.*)$!) {
	my $archive = $1;
	if ($archive =~ $PVE::BackupProvider::Plugin::Borg::ARCHIVE_RE_3) {
	    return ('backup', $archive, $2);
	}
    }

    die "unable to parse Borg volume name '$volname'\n";
}

sub path {
    my ($class, $scfg, $volname, $storeid, $snapname) = @_;

    die "volume snapshot is not possible on Borg volume" if $snapname;

    my $uri = $class->borg_repository_uri($scfg, $storeid);
    my (undef, $archive) = $class->parse_volname($volname);

    return "${uri}::${archive}";
}

sub create_base {
    my ($class, $storeid, $scfg, $volname) = @_;

    die "cannot create base image in Borg storage\n";
}

sub clone_image {
    my ($class, $scfg, $storeid, $volname, $vmid, $snap) = @_;

    die "can't clone images in Borg storage\n";
}

sub alloc_image {
    my ($class, $storeid, $scfg, $vmid, $fmt, $name, $size) = @_;

    die "can't allocate space in Borg storage\n";
}

sub free_image {
    my ($class, $storeid, $scfg, $volname, $isBase) = @_;

    my (undef, $archive) = $class->parse_volname($volname);

    borg_cmd_delete($class, $scfg, $storeid, $archive);

    return;
}

sub list_images {
    my ($class, $storeid, $scfg, $vmid, $vollist, $cache) = @_;

    return []; # guest images are not supported, only backups
}

sub list_volumes {
    my ($class, $storeid, $scfg, $vmid, $content_types) = @_;

    my $res = [];

    return $res if !grep { $_ eq 'backup' } $content_types->@*;

    my $archives = $class->borg_cmd_list($scfg, $storeid)->{archives}
	or die "expected 'archives' key in 'borg list' JSON output missing\n";

    for my $info ($archives->@*) {
	my $archive = $info->{archive};
	my ($vmtype, $backup_vmid, $time_string) =
	    $archive =~ $PVE::BackupProvider::Plugin::Borg::ARCHIVE_RE_3 or next;

	next if defined($vmid) && $vmid != $backup_vmid;

	push $res->@*, {
	    volid => "${storeid}:backup/${archive}",
	    size => 0, # FIXME how to cheaply get?
	    content => 'backup',
	    ctime => parse_backup_time($time_string),
	    vmid => $backup_vmid,
	    format => "borg-archive",
	    subtype => $vmtype,
	}
    }

    return $res;
}

sub status {
    my ($class, $storeid, $scfg, $cache) = @_;

    my $uri = $class->borg_repository_uri($scfg, $storeid);

    my $res;

    if ($uri =~ m!^ssh://!) {
	#FIXME ssh and df on target?
	return;
    } else { # $uri is a local path
	my $timeout = 2;
	$res = PVE::Tools::df($uri, $timeout);

	return if !$res || !$res->{total};
    }


    return ($res->{total}, $res->{avail}, $res->{used}, 1);
}

sub activate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;

    # TODO how to cheaply check? split ssh and non-ssh?

    return 1;
}

sub deactivate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;

    return 1;
}

sub activate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = @_;

    die "volume snapshot is not possible on Borg volume" if $snapname;

    return 1;
}

sub deactivate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = @_;

    die "volume snapshot is not possible on Borg volume" if $snapname;

    return 1;
}

sub get_volume_attribute {
    my ($class, $scfg, $storeid, $volname, $attribute) = @_;

    return;
}

sub update_volume_attribute {
    my ($class, $scfg, $storeid, $volname, $attribute, $value) = @_;

    # FIXME notes or protected possible?

    die "attribute '$attribute' is not supported on Borg volume";
}

sub volume_size_info {
    my ($class, $scfg, $storeid, $volname, $timeout) = @_;

    my (undef, $archive) = $class->parse_volname($volname);
    my (undef, undef, $time_string) =
	$archive =~ $PVE::BackupProvider::Plugin::Borg::ARCHIVE_RE_3;

    my $backup_time = 0;
    if ($time_string) {
	$backup_time = parse_backup_time($time_string)
    } else {
	warn "could not parse time from archive name '$archive'\n";
    }

    my $archives = borg_cmd_info($class, $scfg, $storeid, $archive, $timeout)->{archives}
	or die "expected 'archives' key in 'borg info' JSON output missing\n";

    my $stats = eval { $archives->[0]->{stats} }
	or die "expected entry in 'borg info' JSON output missing\n";
    my ($size, $used) = $stats->@{qw(original_size deduplicated_size)};

    ($size) = ($size =~ /^(\d+)$/); # untaint
    die "size '$size' not an integer\n" if !defined($size);
    # coerce back from string
    $size = int($size);
    ($used) = ($used =~ /^(\d+)$/); # untaint
    die "used '$used' not an integer\n" if !defined($used);
    # coerce back from string
    $used = int($used);

    return wantarray ? ($size, 'borg-archive', $used, undef, $backup_time) : $size;
}

sub volume_resize {
    my ($class, $scfg, $storeid, $volname, $size, $running) = @_;

    die "volume resize is not possible on Borg volume";
}

sub volume_snapshot {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;

    die "volume snapshot is not possible on Borg volume";
}

sub volume_snapshot_rollback {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;

    die "volume snapshot rollback is not possible on Borg volume";
}

sub volume_snapshot_delete {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;

    die "volume snapshot delete is not possible on Borg volume";
}

sub volume_has_feature {
    my ($class, $scfg, $feature, $storeid, $volname, $snapname, $running) = @_;

    return 0;
}

sub rename_volume {
    my ($class, $scfg, $storeid, $source_volname, $target_vmid, $target_volname) = @_;

    die "volume rename is not implemented in Borg storage plugin\n";
}

sub new_backup_provider {
    my ($class, $scfg, $storeid, $bandwidth_limit, $log_function) = @_;

    return PVE::BackupProvider::Plugin::Borg->new(
	$class, $scfg, $storeid, $bandwidth_limit, $log_function);
}

1;
