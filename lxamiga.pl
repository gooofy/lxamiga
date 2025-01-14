#!/usr/bin/perl -w
#
# Simple Linux client for CloanTo Amiga Explorer running on a Commodore Amiga
# Version 2.02 - 2019/09/14
#
# by Mark Street <marksmanuk@gmail.com>
#
# re-sync support, directory creation, rename, baudrate option added by G. Bartsch
#
# Example usage:
# 	lxamiga -l
# 	lxamiga -d df0:
# 	lxamiga -s myfile.txt df0:Empty/myfile.txt
# 	lxamiga -r df0:Empty/remote.txt -w local.txt
# 	lxamiga -r :df0:disk.adf -w image.adf
# 	lxamiga -s image.adf :df0:empty.adf
# 	lxamiga -u df0:Empty/deleteme.txt
# 	lxamiga -f df1: Empty

use strict;
use Device::SerialPort;
use POSIX qw(strftime);
use Time::Local;
use Getopt::Std;
use IO::Socket;
use 5.010;

my $serial;
my $socket;
my $serport     = "/dev/ttyUSB0";
my $serbaud	    = 19200;
my $iphost	    = "192.168.1.200";
my $ipport	    = "356";
my $password	= "AExplorer";
my $maxlen	    = 512;
my $sequence 	= 1;

my %args;
my $usage = "lxamiga by Mark Street <marksmanuk\@gmail.com>\n\nUsage: lxamiga [options]\n".
	"\t-t Use TCP/IP lan connection (dflt. serial)\n".
	"\t-b <baudrate> Set baudrate (dflt: 19200)\n".
	"\t-l List available devices\n".
	"\t-d <volume:path> dir\n".
	"\t-r read file <device:volume/path>\n".
	"\t-s send file <file> <device:volume/path>\n".
	"\t-u <file> delete file\n".
	"\t-m <dir> mkdir\n".
	"\t-R <oldname> <newname> rename file\n".
	"\t-M <oldname> <newname> move file (works across devices)\n".
	"\t-c <oldname> <newname> copy file\n".
	"\t-a <file> <attrs> <comment> set file attrs and comment\n".
	"\t-f <device> Name format disk\n".
	"\t-w <file> write output to filename\n".
	"\t-v Verbose\n";
getopts("tld:r:s:u:f:w:vb:m:R:M:c:a::", \%args) || die $usage;

if ($args{b})
{
    $serbaud = $args{b};
}

initialise();
get_connect();
get_devices()                           if $args{l};
get_directory($args{d})	                if $args{d};
get_file($args{r}, $ARGV[0])            if $args{r};
put_file($args{s}, $ARGV[0])            if $args{s};
del_file($args{u})                      if $args{u};
make_dir($args{m})                      if $args{m};
format_disk($args{f})                   if $args{f};
rename_file($args{R}, $ARGV[0])         if $args{R};
move_file($args{M}, $ARGV[0])           if $args{M};
copy_file($args{c}, $ARGV[0])           if $args{c};
attr_file($args{a}, $ARGV[0], $ARGV[1]) if $args{a};
finalise();

sub Dump
{
	my $buffer = shift;
	my $header = shift;

	die "Undefined buffer" unless defined $buffer;
	die "References not supported" unless ref $buffer eq "";

	my @vals = unpack("C*", $buffer);
	print "$header\n" if defined $header;

	my $rowChars = 16;
	my $pos = 0;

	while ($pos < @vals)
	{
		for (my $i=0; $i<$rowChars; $i++)
		{
			(($pos+$i) < @vals) ? 
				printf "%02X ", $vals[$pos+$i] : print "   ";
		}

		print "\t";
		for (my $i=0; $i<$rowChars; $i++)
		{
			last if $pos+$i >= @vals;
			($vals[$pos+$i] >= 0x20 && $vals[$pos+$i] <= 0x80) ?
				printf "%c",$vals[$pos+$i] : print ".";
		}
		
		print "\n";
		$pos += $rowChars;
	}
}

sub crc32 
{
	my ($input, $init_value, $polynomial) = @_;

	$init_value = 0 unless defined $init_value;
	$polynomial = 0xedb88320 unless defined $polynomial;

	state @lookup_table;

	for (my $i=0; $i<256; $i++) {
   		my $x = $i;
   		for (my $j=0; $j<8; $j++) {
     		if ($x & 1) {
       			$x = ($x >> 1) ^ $polynomial;
     		} else {
       			$x = $x >> 1;
     		}
   		}
   		push @lookup_table, $x;
 	}

	my $crc = $init_value ^ 0xffffffff;

    #printf "crc32... : crc = 0x%08x\n", $crc;
    my $myi = 0;
	foreach my $x (unpack ('C*', $input)) {
   		$crc = (($crc >> 8) & 0xffffff) ^ $lookup_table[ ($crc ^ $x) & 0xff ];
                #printf "crc32: myi=%d x=%02x, crc=%08x\n", $myi, $x, $crc;
                $myi = $myi + 1; 
	}

	$crc = $crc ^ 0xffffffff;
        #printf "crc32... done: crc = 0x%08x\n", $crc;
	return $crc;
}

sub initialise
{
	if ($args{t})
	{
		$socket = new IO::Socket::INET (
    		PeerHost => $iphost,
    		PeerPort => $ipport,
    		Proto    => 'tcp',
		);
		die "Failed to connect to AExplorer on $iphost:$ipport $!\n" unless $socket;
	}
	else
	{
		$serial = new Device::SerialPort($serport, 1) || die "Can't open serial $serport $!\n";
		$serial->baudrate($serbaud);
		$serial->databits(8);
		$serial->parity("none");
		$serial->stopbits(1);
		$serial->handshake("rts");
	}
}

sub finalise
{
	$serial->close if defined $serial;
	$socket->close if defined $socket;
}

sub read_port
{
	my $len = shift;

	return read_serial($len) if defined $serial;
	return read_socket($len) if defined $socket;
}

sub read_serial
{
	my $len = shift || 128;
	my $ret = "";

	$serial->read_char_time(150);

	for (my $tries=0; $tries<5; $tries++)
	{
		my $read = $serial->read($len);
		if ($args{v})
		{
			print "="x73,"\n";
			print "RECEIVED ".(length($read))."/$len BYTES:\n";
			Dump($read);
		}
		$ret .= $read;
		return $ret if length($ret) >= $len || !length($read);
	}
}

sub read_socket
{
	my $len = shift || 128;

	my $maxtries = 5;
	my $read = "";
	do
	{
		my $tries = 0;
		while (!is_data_waiting($socket) && $tries++ < $maxtries)
		{
			print "No data waiting ($tries), retry...\n" if $args{v};
		}
		return $read if $tries >= $maxtries;
		my $remain = $len - length($read);
		print "Reading $remain bytes from socket\n" if $args{v};
		my $buffer;
		$socket->recv($buffer, $remain);
		print "="x73,"\n" if $args{v};
		print "RECEIVED ".(length($buffer))." (".
			(length($read)+length($buffer))."/$len) BYTES:\n" if $args{v};
		Dump($buffer) if $args{v};
		$read .= $buffer;
	}
	while (length($read) != $len);
	return $read;
}

sub is_data_waiting
{
	my $fh    = shift || die "Undefined FH";
	my $ticks = shift || 0.20;

	my $rmask = "";
	vec($rmask, fileno($fh), 1) = 1;
	(my $num, $rmask) = select($rmask, undef, undef, $ticks);
	return $num;
}

sub write_port
{
	my $msg = shift;

	print "="x73,"\n" if $args{v};
	print "SENDING ".(length($msg))." BYTES:\n" if $args{v};
	# Dump($msg) if $args{v};

	write_serial($msg) if defined $serial;
	write_socket($msg) if defined $socket;
}

sub write_serial
{
	my $msg = shift;
	$serial->write($msg);
}

sub write_socket
{
	my $msg = shift;
	$socket->send($msg);
}

sub write_ack
{
	write_port("PkOk");
}

sub write_not_ack
{
	write_port("PkRs");
}

sub read_message
{
	my $rx;
    my $head;
	my $head_ok    = 1;
	my $payload_ok = 1;

    do {			         				# repeat until CRC is ok

        # header

		for (my $i=0; $i<10; $i++)
		{
			$rx = read_port(12);			# Header
			last if length($rx);
			sleep(1);
		}
		die "Message timeout error" unless length($rx);

		# decode header

		my ($id, $len, $seq, $head_crc) = unpack("nnNN", $rx);
		my $calc_crc = crc32(substr($rx, 0, 12-4));

		if ($args{v})
		{
			printf "  Message  = %02X\n", $id;
			printf "  Length   = %d\n", $len;
			printf "  Sequence = %d\n", $seq;
			printf "  CRC32    = %04X (%04X)\n", $head_crc, $calc_crc;
		}

		my $head_ok = $head_crc == $calc_crc;

		printf "Mismatched CRC on header (%04X/%04X) message $id\n", $head_crc, $calc_crc
			if (!$head_ok);

		$head = {
			    id	 	=> $id,
			    len		=> $len,
			    sequence 	=> $seq,
			   };

		if ( $head_ok && $head->{len} )
		{
			$rx = read_port($head->{len});	# Payload
			my $crc = read_port(4);			# CRC32 for payload
			$crc = unpack("N", $crc);

			my $calc_crc = crc32($rx);
			printf "  CRC32 = %04X (%04X)\n", $crc, $calc_crc if $args{v};

			$payload_ok = $crc == $calc_crc;

			printf "Mismatched CRC on payload (%04X/%04X)\n", $crc, $calc_crc
				if (!$payload_ok);
		}


		if ( !$head_ok || !$payload_ok )
        {
            # read pending bytes (there might have been payload)
            do
            {
                $rx = read_port($maxlen);
			} until (length($rx) eq 0);

		    write_not_ack();
        }

	} until $head_ok && $payload_ok ;

	write_ack();

	return 
	{
		header  => $head,
		payload => $rx,
	}
}

sub read_ack
{
	for (my $i=0; $i<5; $i++)
	{
		my $ack = read_port(4);
		return $ack if length($ack);
		sleep 1;
	}
}

sub write_message
{
	my $id 	    = shift;
	my $payload = shift;
    my $ack;

	do
    {

		my $msg = pack("n", $id);
		$msg .= pack("n", length($payload));
		$msg .= pack("N", $sequence++);	

		my $crc = crc32($msg);
		$msg .= pack("N", $crc);

		if ($args{v})
		{
			print "="x73,"\n";
			print "WRITE MESSAGE:\n";
			printf "  Message    = %04X\n", $id;
			printf "  Length     = %d\n", length($payload);
			printf "  Sequence   = %d\n", $sequence-1;
			printf "  Header CRC = %08X\n", $crc;
		}

		if (length($payload))
		{
			$msg .= $payload;
			$crc = crc32($payload);
			$msg .= pack("N", $crc);
			# Dump($payload, "WRITE PAYLOAD") if $args{v};
		}

		write_port($msg);
		
		$ack = read_ack();
        
		if ($ack ne "PkOk")
		{
            print "NACK $ack received -> resync.";
        }
	} until $ack eq "PkOk";
}

sub get_connect
{
	my $initmsg = "Cloanto(r)";
		
	# The password (only required for TCP/IP) is sent as a 4 byte
	# CRC32 hash appended to the end of the login string.
	if (defined $password)
	{
		my $crc = crc32($password);
		$initmsg .= pack("N", $crc);
	}

	# Send 0x0002 message and wait 0x0002 response:
	write_message(2, $initmsg);

	my $rx = read_message();
	die "Unexpected message received ($rx)" unless $rx->{payload} =~ /Cloanto/;

	print "Connected to host successfully at $serbaud baud.\n" if defined $serial;
	print "Connected to $iphost:$ipport successfully.\n" if defined $socket;
}

sub get_multipart
{
	# Retrieve multipart response from host.  Host returns a 0x0003 message with
	# total payload bytes followed by multiple 0x0005 msgs and terminated with
	# final 0x0004.

	my $rx = read_message();	# Should be 0x0003
	die "Invalid request ($rx->{header}{id})" if $rx->{header}{id} != 0x0003;

	my $total = unpack "N", $rx->{payload};
	printf "  Expecting %d total Bytes\n", $total if $args{v}; 

	my $msg = "";	
	do
	{
		write_message(0x0000, "");	# Send 0x0000 to solicit reply

		$rx = read_message();
		if ($rx->{header}{len})
		{
			my $offset = unpack "N", $rx->{payload};
			die "Lost multipart response (Got $offset, expecting ".(length($msg)).")\n"
				if $offset != length($msg);
			$msg .= substr $rx->{payload}, 4;
			printf "\rRead %d/%d Bytes %.1f%%", 
				length($msg), $total, (length($msg)/$total)*100;
			flush STDOUT;
		}
	}
	while ($rx->{header}{id} == 0x0005);	# Received last part

	my $len = length($msg);
	print "\n" if $len;
	print "TOTAL RECEIVED $len BYTES:\n" if $args{v};
	Dump($msg) if $args{v};

	die "Expecting $total Bytes but received $len" if $total != $len;
	return $msg;
}

sub put_multipart
{
	# Host will solicit each part with 0x0000.
	my $data = shift || die "Nothing to send";
	my $overwrite = shift;

	my $len = length($data);
	print "SENDING $len BYTES\n" if $args{v};

	# Wait for first 0x0000
	my $rx = read_message();

	if ($rx->{header}{id} != 0x0000)
	{
		write_message(0x0000, "");
		die "File exists ($rx->{header}{id})"
			if !$overwrite && $rx->{header}{id} == 0x0008;
	}

	# Send 0x0003 prefix:
	my $payload = pack "NN", $len, 0x00000200;
	write_message(0x0003, $payload);

	# Send 0x0005 parts:
	my $buffer = $data;
	my $sent = 0;
	while (length($buffer))
	{
		# Wait for host to solicit reply with 0x0000:
		$rx = read_message();
		die "Invalid request ($rx->{header}{id})" if $rx->{header}{id} != 0x0000;

		# Send next part:
		my $num_tx = length($buffer);
		$num_tx = $maxlen-4 if $num_tx > $maxlen-4;

		my $tx = pack "N", $sent;
		$tx .= substr($buffer, 0, $num_tx);
		write_message(0x0005, $tx);

		$buffer = substr($buffer, $num_tx);
		$sent += $num_tx;

		printf "\rSent %d/%d Bytes %.1f%%", $sent, $len, ($sent/$len)*100;
		flush STDOUT;
	}

	print "\n" if $sent;

	# Wait for host to solicit reply with 0x0000:
	$rx = read_message();
	die "Invalid request ($rx->{header}{id})" if $rx->{header}{id} != 0x0000;

	# Send final 0x0004:
	write_message(0x0004, "");
}

sub send_close
{
	# Send 0x006D and await 0x000A response:
	write_message(0x006D, "");

	my $rx = read_message();
	die "Expected 0x000A reply ($rx->{header}{id})" if $rx->{header}{id} != 0x000A;
}

sub get_devices
{
	return get_directory("");
}

sub get_directory
{
	my $device = shift;

	# Send 0x0064 message and wait 0x0003 response:
	write_message(0x0064, $device."\x00\x01");

	my $msg_devices = get_multipart();
	send_close();

	# Decode response:
	my ($num_devices) = unpack("N", $msg_devices);
	print "Number of entries: $num_devices\n" if $args{v};
	return unless $num_devices;

	my @ret;
	my $msg = substr $msg_devices, 4;


	for (my $i=0; $i<$num_devices; $i++)
	{
		my $len = unpack("N", $msg);
		printf "Device %d, expecting %X (%d) bytes\n", $i+1, $len, $len if $args{v};

		my ($size, $used)	= unpack("x[N]NN", $msg);
		my ($type, $atts)	= unpack("x[NNN]nn", $msg);
		my ($date, $time) 	= unpack("x[NNNN]NN", $msg);
		my ($ctime)    		= unpack("x[NNNNNN]N", $msg);
		my ($type2)    		= unpack("x[NNNNNNN]C", $msg);
		my ($name) 			= unpack("x[NNN]x17Z*", $msg);
		my $comment			= ($msg =~ /\Q$name\E\0(.*?)\0/s)[0];

		my $bits = "";
		$bits .= "S" if  $atts&0x40;
		$bits .= "P" if  $atts&0x20;
		$bits .= "A" if  $atts&0x10;
		$bits .= "R" if ~$atts&0x08;
		$bits .= "W" if ~$atts&0x04;
		$bits .= "E" if ~$atts&0x02;
		$bits .= "D" if ~$atts&0x01;

		my $date_t = ($date*24*60*60)+(2922*24*60*60)+($time*60);	# Amiga epoch 1/1/1978
		my $date_str = strftime "%d/%m/%Y %H:%M", gmtime $date_t;

		my $dir = 0;
		$dir = 1 if $type & 0x8000 && $name !~ /:/;

		$comment =~ s/[\n\r]/|/g;

		if ($args{v})
		{
			printf " name   = %s\n", $name;
			printf " comment= %s\n", $comment;
			printf " atts   = %04X $bits\n", $atts;
			printf " date   = %04X %04X (%s)\n", $date, $time, $date_str;
			printf " size   = %d Bytes (%d kB)\n", $size, $size/1024;
			printf " used   = %d Bytes (%d kB)\n", $used, $used/1024;
			printf " type   = %04X\n", $type;	
			printf " type2  = %02X\n", $type2;
			printf " ctime  = %08X\n", $ctime;
		}

		push @ret, {
			name 		=> $name,
			comment 	=> $comment,	
			atts		=> $bits,
			date		=> $date_str,
			size		=> $size,
			used		=> $used,
			type		=> $type2,
			dir			=> $dir,
		};

		die "Invalid offset ($len) for remaining payload (".(length($msg)).")" if $len > length($msg);
		$msg = substr $msg, $len;
	}

	if ($args{v})
	{
		print "Remaining bytes (".(length($msg))."):\n";
		Dump($msg);
	}

	@ret = sort { $a->{type} <=> $b->{type} or $a->{name} cmp $b->{name} } @ret;
	print scalar @ret, " entries:\n";

	foreach my $ref (@ret)
	{
		printf " %-21s", $ref->{name};
		printf " %8d kB %8d kB", $ref->{used}/1024, $ref->{size}/1024 if $ref->{name} =~ /:/;
		printf " %8d", $ref->{size} if $ref->{name} !~ /:/ && $ref->{type} != 0x02;
		printf "    (dir)", if $ref->{type} == 0x02;
		printf " %-16s", $ref->{date};
		printf " %-7s", $ref->{atts};
		printf " %15s", substr($ref->{comment}, 0, 19);
		printf "\n";
	}
}

sub get_file
{
	my $device = shift;
	my $outfile = shift;

	$outfile = $args{w} if defined $args{w};
	print "Downloading $device to $outfile\n" if defined $outfile;

	# Send 0x0065 message and wait 0x0003 response:
	write_message(0x0065, $device."\x00");

	my $rx = get_multipart;
	send_close();
	
	print "$rx\n" unless defined $outfile;

	# Write buffer to file:
	if (defined $outfile)
	{
		die "Output file ($outfile) already exists!" if -r $outfile;
		open (OUT, "> $outfile") || die $!;
		print OUT $rx;
		close OUT;
		print length($rx)." bytes written to file.\n";
	}
}

sub put_file
{
	my $src = shift || die "Unspecified source file";
	my $dst = shift	|| die "Unspecified destination path";

	$src =~ s/\\//g;
	die "Source file ($src) not found!" unless -r $src;

	if ($dst =~ /^\w+:$/ || $dst =~ /\w+:.*\/$/)	# Assume destination = source filename
	{
		my $name = $src;
		$name =~ s/.*\///;
		$dst .= "\/" unless $dst =~ /\/$/;
		$dst .= $name;
	}

	die "Destination file ($dst) invalid" unless $dst =~ /\w+:.+/;
	print "Uploading $src to $dst\n";

	my $file_size = (stat($src))[7];
	print "File $src = $file_size Bytes\n" if $args{v};

	die "Unsupported invalid/extended ADF ($file_size Bytes)"
		if $file_size != 901120 && $dst =~ /.adf$/i;

	my $dtime = (timegm(0,0,0,(localtime)[3,4,5])-timelocal(0,0,0,(localtime)[3,4,5]))/60;
	my $modify = (stat($src))[9];
	my $date = ($modify-(2922*24*60*60))/60/60/24;	# Hours since 1/1/78
	my $time = (($modify/60)%1440)+$dtime;			# Mins since midnight, local

	# Construct message:
	my $filename = $dst.pack "NC", 0, 0;

	my $msg = pack "N", length($filename) + 29;		# Header size
	$msg .= pack "N", $file_size;					# File size in bytes
	$msg .= pack "N", 0;							# ???
	$msg .= pack "N", 0x00000000;					# Attributes
	$msg .= pack "NN", $date, $time;				# Date & Time
	$msg .= pack "N", 0x00000000;					# ctime ref
	$msg .= pack "C", 0x03;							# File type
	$msg .= $filename;
	
	# Send 0x0066 message and wait 0x0000 response:
	write_message(0x0066, $msg);

	# Send file:
	my $data;
	open(IN, "< $src") || die $!;
	binmode IN;
	local $/ = undef;	# Slurp!
	$data = <IN>;
	close IN;

	my $overwrite = 0;
	$overwrite = 1 if $dst =~ /\.adf/i;

	put_multipart($data, $overwrite);
	send_close();
}

sub del_file
{
	my $file = shift || die "Unspecified file";
	
	write_message(0x0067, $file."\x00");

	my $rx = read_message();
	die "Invalid request ($rx->{header}{id})" if $rx->{header}{id} != 0x0000;

	send_close();
	print "File deleted.\n";
}

sub make_dir
{
	my $dir = shift || die "Unspecified directory name";

	my $dtime = (timegm(0,0,0,(localtime)[3,4,5])-timelocal(0,0,0,(localtime)[3,4,5]))/60;
	#my $modify = (stat($dir))[9];
	my $modify = time();
	my $date = ($modify-(2922*24*60*60))/60/60/24;	# Hours since 1/1/78
	my $time = (($modify/60)%1440)+$dtime;			# Mins since midnight, local

	# Construct message:
	my $filename = $dir.pack "NC", 0, 0;

	my $msg = pack "N", length($filename) + 29;		# Header size
	$msg .= pack "N", 0;         					# File size in bytes
	$msg .= pack "N", 0;							# ???
	$msg .= pack "N", 0x00000000;					# Attributes
	$msg .= pack "NN", $date, $time;				# Date & Time
	$msg .= pack "N", 0x00000000;					# ctime ref
	$msg .= pack "C", 0x02;							# File type: directory
	$msg .= $filename;
	
	# Send 0x0066 message
	write_message(0x0066, $msg);
    
    # wait for 0x00 response:
	my $rx = read_message();

	if ($rx->{header}{id} != 0x0000)
	{
	    print "makedir $dir failed\n";
	}
    else
    {
	    print "makedir $dir ok\n";
    }

	send_close();
}

sub rename_file
{
	my $oldname = shift || die "Unspecified oldname";
	my $newname = shift	|| die "Unspecified newname";

	print "renaming $oldname to $newname\n";

	# Construct message:
    my $msg = $oldname;
    $msg .= pack "C", 0x00;
    $msg .= $newname;
    $msg .= pack "C", 0x00;
	
	# Send 0x0068 message
	write_message(0x0068, $msg);

    # wait for 0x00 response:
	my $rx = read_message();

	if ($rx->{header}{id} != 0x0000)
	{
	    print "rename failed\n";
	}

	send_close();
}

sub move_file
{
	my $oldname = shift || die "Unspecified oldname";
	my $newname = shift	|| die "Unspecified newname";

	print "moving $oldname to $newname\n";

	# Construct message:
    my $msg = $oldname;
    $msg .= pack "C", 0x00;
    $msg .= $newname;
    $msg .= pack "C", 0x00;
	
	# Send 0x0069 message
	write_message(0x0069, $msg);

    # wait for 0x00 response:
	my $rx = read_message();

	if ($rx->{header}{id} != 0x0000)
	{
	    print "move failed\n";
	}

	send_close();
}

sub copy_file
{
	my $oldname = shift || die "Unspecified oldname";
	my $newname = shift	|| die "Unspecified newname";

	print "copying $oldname to $newname\n";

	# Construct message:
    my $msg = $oldname;
    $msg .= pack "C", 0x00;
    $msg .= $newname;
    $msg .= pack "C", 0x00;
	
	# Send 0x006a message
	write_message(0x006a, $msg);

    # wait for 0x00 response:
	my $rx = read_message();

	if ($rx->{header}{id} != 0x0000)
	{
	    print "copy failed\n";
	}

	send_close();
}

sub attr_file
{
	my $filename = shift || die "Unspecified filename";
	my $attrs = shift	|| die "Unspecified attrs";
	my $comment = shift	|| die "Unspecified comment";

	print "attrs $filename: attrs=$attrs, comment: $comment\n";

	# Construct message:
    my $msg = pack "N", int($attrs);
    $msg .= $filename;
    $msg .= pack "C", 0x00;
    $msg .= $comment;
    $msg .= pack "C", 0x00;
	
	# Send 0x006b message
	write_message(0x006b, $msg);

    # wait for 0x00 response:
	my $rx = read_message();

	if ($rx->{header}{id} != 0x0000)
	{
	    print "attrs failed\n";
	}

	send_close();
}

sub format_disk
{
	my $device = shift || die "Unspecified device";
	my $name = $ARGV[0] || "Empty";

	die "Invalid device specification ($device)" unless $device =~ /^\w+\:$/;
	print "Formatting $device $name\n";

	my $opts = 0x00;	# TODO support filesytem and format options
	my $msg = "DOS\1".(pack "N", $opts)."$device\0$name\0EXE";
	write_message(0x006e, $msg);

	# Read reply from host (ignore any warnings):
	my $rx = read_message();
	if ($rx->{header}{id} != 0x0000 && $rx->{header}{id} != 0x0008)
	{
		send_close();	# Abort
		die "Disk is not writable ($rx->{header}{id})"
			if $rx->{header}{id} == 0x0002;
		die "Rejected ($rx->{header}{id}) Write Protect or Requires KS 2.0+"
			if $rx->{header}{id} == 0x0001;		# KS 1.3
		die "Unexpected message received ($rx->{header}{id})";
	}

	if ($rx->{header}{id} == 0x0008) 	# Write protect
	{
		write_message(0x0000, "");	# Continue
	}
	
	# Read 0x000B from host:
	$rx = read_message();
	die "Unexpected message received ($rx->{header}{id})" if $rx->{header}{id} != 0x000B;

	my $total = unpack "N", $rx->{payload};		# Number of tracks + 1
	my $i = 0;

	while($i++ < $total)
	{
		# Read 0x000 from host:
		print "Reading $i/$total\n" if $args{v};
		printf "\rFormatting %0.1f%%", ($i/$total)*100;
		flush STDOUT;

		$rx = read_message();
		die "Unexpected message received ($rx->{header}{id})" if $rx->{header}{id} != 0x0000;
	
		# Send 0x0000 to host:
		write_message(0x0000, "");
	}

	print "\nFinished.\n";
	send_close();
}

