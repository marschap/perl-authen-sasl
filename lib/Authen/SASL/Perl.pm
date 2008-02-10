# Copyright (c) 2002 Graham Barr <gbarr@pobox.com>. All rights reserved.
# This program is free software; you can redistribute it and/or
# modify it under the same terms as Perl itself.

package Authen::SASL::Perl;

use strict;
use vars qw($VERSION);
use Carp;

$VERSION = "1.05";

my %secflags = (
	noplaintext  => 1,
	noanonymous  => 1,
	nodictionary => 1,
);
my %have;

sub client_new {
  my ($pkg, $parent, $service, $host, $secflags) = @_;

  my @sec = grep { $secflags{$_} } split /\W+/, lc($secflags || '');

  my $self = {
    callback => { %{$parent->callback} },
    service  => $service  || '',
    host     => $host     || '',
    debug    => $parent->{debug} || 0,
  };

  my @mpkg = sort {
    $b->_order <=> $a->_order
  } grep {
    my $have = $have{$_} ||= (eval "require $_;" and $_->can('_secflags')) ? 1 : -1;
    $have > 0 and $_->_secflags(@sec) == @sec
  } map {
    (my $mpkg = __PACKAGE__ . "::$_") =~ s/-/_/g;
    $mpkg;
  } split /[^-\w]+/, $parent->mechanism
    or croak "No SASL mechanism found\n";

  $mpkg[0]->_init($self);
}

sub _order   { 0 }
sub code     { defined(shift->{error}) || 0 }
sub error    { shift->{error}    }
sub service  { shift->{service}  }
sub host     { shift->{host}     }

sub set_error {
  my $self = shift;
  $self->{error} = shift;
  return;
}

# set/get property
sub property {
  my $self = shift;
  my $prop = $self->{property} ||= {};
  return $prop->{ $_[0] } if @_ == 1;
  my %new = @_;
  @{$prop}{keys %new} = values %new;
  1;
}

sub callback {
  my $self = shift;

  return $self->{callback}{$_[0]} if @_ == 1;

  my %new = @_;
  @{$self->{callback}}{keys %new} = values %new;

  $self->{callback};
}

# Should be defined in the mechanism sub-class
sub mechanism    { undef }
sub client_step  { undef }
sub client_start { undef }

# Private methods used by Authen::SASL::Perl that
# may be overridden in mechanism sub-calsses

sub _init {
  my ($pkg, $href) = @_;

  bless $href, $pkg;
}

sub _call {
  my ($self, $name) = splice(@_,0,2);

  my $cb = $self->{callback}{$name};

  return undef unless defined $cb;

  my $value;

  if (ref($cb) eq 'ARRAY') {
    my @args = @$cb;
    $cb = shift @args;
    $value = $cb->($self, @args);
  }
  elsif (ref($cb) eq 'CODE') {
    $value = $cb->($self, @_);
  }
  else {
    $value = $cb;
  }

  $self->{answer}{$name} = $value
    unless $name eq 'pass'; # Do not store password

  return $value;
}

# TODO: Need a better name than this
sub answer {
  my ($self, $name) = @_;
  $self->{answer}{$name};
}

sub _secflags { 0 }

sub securesocket {
  my $self = shift;
  return $_[0] unless ($self->property('ssf') > 0);

  local *GLOB; # avoid used only once warning
  my $glob = \do { local *GLOB; };
  tie(*$glob, 'Authen::SASL::Perl::Layer', $_[0], $self);
  $glob;
}

{

#
# Add SASL encoding/decoding to a filehandle
#

  package Authen::SASL::Perl::Layer;

  use bytes;

  require Tie::Handle;
  our @ISA = qw(Tie::Handle);

  sub TIEHANDLE {
    my ($class, $fh, $conn) = @_;
    my $self;

    warn __PACKAGE__ . ': non-blocking handle may not work'
      if ($fh->can('blocking') and not $fh->blocking());

    $self->{fh}         = $fh;
    $self->{conn}       = $conn;
    $self->{readbuflen} = 0;
    $self->{sndbufsz}   = $conn->property('maxout');
    $self->{rcvbufsz}   = $conn->property('maxbuf');

    return bless($self, $class);
  }

  sub CLOSE {
    my ($self) = @_;

    # forward close to the inner handle
    close($self->{fh});
    delete $self->{fh};
  }

  sub DESTROY {
    my ($self) = @_;
    delete $self->{fh};
    undef $self;
  }

  sub FETCH {
    my ($self) = @_;
    return $self->{fh};
  }

  sub FILENO {
    my ($self) = @_;
    return fileno($self->{fh});
  }


  sub READ {
    my ($self, $buf, $len, $offset) = @_;
    my $debug = $self->{conn}->{debug};

    $buf = \$_[1];

    my $avail = $self->{readbuflen};

    print STDERR " [READ(len=$len,offset=$offset)] avail=$avail;\n"
      if ($debug & 4);

    # Check if there's leftovers from a previous READ
    if ($avail <= 0) {
      $avail = $self->_getbuf();
      return undef unless ($avail > 0);
    }

    # if there's more than we need right now, leave the rest for later
    if ($avail >= $len) {
      print STDERR "   GOT ALL: avail=$avail; need=$len\n"
        if ($debug & 4);
      substr($$buf, $offset, $len) = substr($self->{readbuf}, 0, $len, '');
      $self->{readbuflen} -= $len;
      return ($len);
    }

    # there's not enough; take all we have, read more on next call
    print STDERR "   GOT PARTIAL: avail=$avail; need=$len\n"
      if ($debug & 4);
    substr($$buf, $offset, $avail) = $self->{readbuf};
    $self->{readbuf}    = '';
    $self->{readbuflen} = 0;

    return ($avail);
  }

  # retrieve and decode a buffer of cipher text in SASL format
  sub _getbuf {
    my ($self) = @_;
    my $debug  = $self->{conn}->{debug};
    my $fh     = $self->{fh};
    my $buf    = '';

    # first, read 4-octet buffer size
    my $n = 0;
    while ($n < 4) {
      my $rv = sysread($fh, $buf, 4 - $n, $n);
      print STDERR "    [getbuf: sysread($fh,$buf,4-$n,$n)=$rv: $!\n"
        if ($debug & 4);
      return $rv unless $rv > 0;
      $n += $rv;
    }

    # size is encoded in network byte order
    my ($bsz) = unpack('N', $buf);
    print STDERR "    [getbuf: cipher buffer sz=$bsz]\n" if ($debug & 4);
    return undef unless ($bsz <= $self->{rcvbufsz});

    # next, read actual cipher text
    $buf = '';
    $n   = 0;
    while ($n < $bsz) {
      my $rv = sysread($fh, $buf, $bsz - $n, $n);
      print STDERR "    [getbuf: got o=$n,n=", $bsz - $n, ",rv=$rv,bl=" . length($buf) . "]\n"
        if ($debug & 4);
      return $rv unless $rv > 0;
      $n += $rv;
    }

    # call mechanism specific decoding routine
    $self->{readbuf} = $self->{conn}->decode($buf, $bsz);
    $n = length($self->{readbuf});
    print STDERR "    [getbuf: clear text buffer sz=$n]\n" if ($debug & 4);
    $self->{readbuflen} = $n;
  }


  # Encrypting a write() to a filehandle is much easier than reading, because
  # all the data to be encrypted is immediately available
  sub WRITE {
    my ($self, undef, $len, $offset) = @_;
    my $debug = $self->{conn}->{debug};

    my $fh = $self->{fh};

    # put on wire in peer-sized chunks
    my $bsz = $self->{sndbufsz};
    while ($len > 0) {
      print STDERR " [WRITE: chunk $bsz/$len]\n"
        if ($debug & 8);

      # call mechanism specific encoding routine
      my $x = $self->{conn}->encode(substr($_[1], $offset, $bsz));
      print $fh pack('N', length($x)), $x;
      $len -= $bsz;
      $offset += $bsz;
    }

    return $_[2];
  }

}

1;
