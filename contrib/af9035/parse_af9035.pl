#!/usr/bin/perl
use strict;
use Getopt::Long;

#   Copyright (C) 2014 Mauro Carvalho Chehab
#
#   This program is free software; you can redistribute it and/or modify
#   it under the terms of the GNU General Public License as published by
#   the Free Software Foundation, version 2 of the License.
#
#   This program is distributed in the hope that it will be useful,
#   but WITHOUT ANY WARRANTY; without even the implied warranty of
#   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#   GNU General Public License for more details.
#
# This small script parses USB dumps generated by several drivers,
# decoding USB bits.
#
# To use it, do:
# dmesg | ./parse_usb.pl
#
# Also, there are other utilities that produce similar outputs, and it
# is not hard to parse some USB analyzers log into the expected format.
#

my $debug = 0;
my $show_timestamp = 0;

my $argerr = "Invalid arguments.\nUse $0 [--debug] [--show_timestamp]\n";

GetOptions(
	'show_timestamp' => \$show_timestamp,
	'debug' => \$debug,
) or die $argerr;


my $ctrl_ep = 0x02;
my $resp_ep = 0x81;

my %cmd_map = (
	0x00 => "CMD_MEM_RD",
	0x01 => "CMD_MEM_WR",
	0x02 => "CMD_I2C_RD",
	0x03 => "CMD_I2C_WR",
	0x04 => "CMD_EEPROM_READ",
	0x05 => "CMD_EEPROM_WRITE",
	0x18 => "CMD_IR_GET",
	0x21 => "CMD_FW_DL",
	0x22 => "CMD_FW_QUERYINFO",
	0x23 => "CMD_FW_BOOT",
	0x24 => "CMD_FW_DL_BEGIN",
	0x25 => "CMD_FW_DL_END",
	0x29 => "CMD_FW_SCATTER_WR",
	0x2a => "CMD_GENERIC_I2C_RD",
	0x2b => "CMD_GENERIC_I2C_WR",
);

my @stack;

sub print_send_race($$$$$$)
{
	my ( $timestamp, $ep, $len, $mbox, $cmd, $payload ) = @_;

	my $data = pop @stack;
	if (!$data && !$payload =~ /ERROR/) {
		printf "Missing control cmd\n";
		return;
	}

	my ( $ctrl_ts, $ctrl_ep, $ctrl_len, $ctrl_seq, $ctrl_mbox, $ctrl_cmd, @ctrl_bytes ) = @$data;

	if ($cmd eq "CMD_MEM_RD" && scalar(@ctrl_bytes) >= 6 && ($ctrl_cmd eq "CMD_MEM_WR" || $ctrl_cmd eq "CMD_MEM_RD")) {
		my $wlen;

		$wlen = shift @ctrl_bytes;
		shift @ctrl_bytes;
		shift @ctrl_bytes;
		shift @ctrl_bytes;

		my $reg = $ctrl_mbox << 16;
		$reg |= (shift @ctrl_bytes) << 8;
		$reg |= (shift @ctrl_bytes);

		my $ctrl_pay;
		for (my $i =  0; $i < scalar(@ctrl_bytes); $i++) {
			if ($i == 0) {
				$ctrl_pay .= sprintf "0x%02x", $ctrl_bytes[$i];
			} else {
				$ctrl_pay .= sprintf ", 0x%02x", $ctrl_bytes[$i];
			}
		}

		if ($ctrl_cmd eq "CMD_MEM_WR") {
			my $comment;

			$comment = "\t/* $payload */" if ($payload =~ /ERROR/);

			if (scalar(@ctrl_bytes) > 1) {
				printf "ret = af9035_wr_regs(d, 0x%04x, $ctrl_len, { $ctrl_pay });$comment\n", $reg;
			} else {
				printf "ret = af9035_wr_reg(d, 0x%04x, $ctrl_pay);$comment\n", $reg;
			}
			return;
		}
		if ($ctrl_cmd eq "CMD_MEM_RD") {
			my $comment = "\t/* read: $payload */";
			if (scalar(@ctrl_bytes) > 0) {
				printf "ret = af9035_rd_regs(d, 0x%04x, $ctrl_len, { $ctrl_pay }, $len, rbuf);$comment\n", $reg;
			} else {
				printf "ret = af9035_rd_reg(d, 0x%04x, &val);$comment\n", $reg;
			}
			return;
		}
	}

	if ($cmd eq "CMD_MEM_RD" && ($ctrl_cmd =~ /CMD_FW_(QUERYINFO|DL_BEGIN|DL_END)/)) {
		my $comment = "\t/* read: $payload */" if ($payload);
		printf "struct usb_req req = { $ctrl_cmd, $ctrl_mbox, $len, wbuf, sizeof(rbuf), rbuf }; ret = af9035_ctrl_msg(d, &req);$comment\n";
		next;
	}

	my $ctrl_pay;
	for (my $i = 0; $i < scalar(@ctrl_bytes); $i++) {
		if ($i == 0) {
			$ctrl_pay .= sprintf "0x%02x", $ctrl_bytes[$i];
		} else {
			$ctrl_pay .= sprintf ", 0x%02x", $ctrl_bytes[$i];
		}
	}

	if ($ctrl_cmd eq "CMD_FW_DL") {
		printf "af9015_wr_fw_block(%d, { $ctrl_pay };\n", scalar(@ctrl_bytes);
		next;
	}

	$payload=", bytes = $payload" if ($payload);

	printf("%slen=%d, seq %d, mbox=0x%02x, cmd=%s, bytes= %s\n",
		$ctrl_ts, $ctrl_len, $ctrl_seq, $ctrl_mbox, $ctrl_cmd, $ctrl_pay);
	if ($payload =~ /ERROR/) {
		printf("\t$payload\n");
	} elsif ($cmd ne "CMD_FW_DL") {
		printf("\t%sACK: len=%d, mbox=0x%02x, cmd=%s%s\n",
			$timestamp, $len, $mbox, $cmd, $payload);
	}
}

while (<>) {
	if (m/(\d+)\s+ms\s+(\d+)\s+ms\s+\((\d+)\s+us\s+EP\=([\da-fA-F]+).*[\<\>]+\s*(.*)/) {
		my $timestamp = sprintf "%09u ms %6u ms %7u us ", $1, $2, $3;
		my $ep = hex($4);
		my $payload = $5;

		printf("// %sEP=0x%02x: %s\n", $timestamp, $ep, $payload) if ($debug);

		$timestamp = "" if (!$show_timestamp);

		if ($payload =~ /ERROR/) {
			print_send_race($timestamp, $ep, 0, 0, 0, $payload);
			next;
		}

		next if (!($ep == $ctrl_ep || $ep == $resp_ep));

		my @bytes = split(/ /, $payload);
		for (my $i = 0; $i < scalar(@bytes); $i++) {
			$bytes[$i] = hex($bytes[$i]);
		}

		my $len = shift @bytes;
		my $mbox = shift @bytes;
		my $cmd = shift @bytes;
		my $seq;

		my $header_size;
		# Discount checksum and header length
		if ($ep == $ctrl_ep) {
			$seq = shift @bytes;
			$header_size = 4;
		} else {
			$header_size = 3;
		}
		$len -= 1 + $header_size;
		if (defined($cmd_map{$cmd})) {
			$cmd = $cmd_map{$cmd};
		} else {
			$cmd = sprintf "unknown 0x%02x", $cmd;
		}
		my $checksum = pop @bytes;
		$checksum |= (pop @bytes) << 8;

		if ($ep == $ctrl_ep) {
			my @data = ( $timestamp, $ep, $len, $seq, $mbox, $cmd, @bytes );
			push @stack, \@data;

			if ($cmd eq "CMD_FW_DL") {
				print_send_race($timestamp, $ep, 0, 0, $cmd, "");
			}

			next;
		}

		my $pay;
		# Print everything, except the checksum
		for (my $i = 0; $i < scalar(@bytes); $i++) {
			if (!$i) {
				$pay .= sprintf "0x%02x", $bytes[$i];
			} else {
				$pay .= sprintf ", 0x%02x", $bytes[$i];
			}
		}

		print_send_race($timestamp, $ep, $len, $mbox, $cmd, $pay);
	}
}
