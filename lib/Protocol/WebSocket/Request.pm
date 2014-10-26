package Protocol::WebSocket::Request;

use strict;
use warnings;

use base 'Protocol::WebSocket::Message';

use Protocol::WebSocket::Cookie::Request;

require Carp;

sub new {
    my $self = shift->SUPER::new(@_);

    $self->state('request_line');

    $self->{max_request_size} ||= 2048;

    $self->{cookies} ||= [];

    return $self;
}

sub cookies { shift->{cookies} }

sub resource_name {
    @_ > 1 ? $_[0]->{resource_name} = $_[1] : $_[0]->{resource_name} || '/';
}

sub parse {
    my $self  = shift;
    my $chunk = shift;

    return 1 unless length $chunk;

    return if $self->error;

    $self->{buffer} .= $chunk;
    $chunk = $self->{buffer};

    if (length $chunk > $self->{max_request_size}) {
        $self->error('Request is too big');
        return;
    }

    while ($chunk =~ s/^(.*?)\x0d\x0a//) {
        my $line = $1;

        if ($self->state eq 'request_line') {
            my ($req, $resource_name, $http) = split ' ' => $line;

            unless ($req && $resource_name && $http) {
                $self->error('Wrong request line');
                return;
            }

            unless ($req eq 'GET' && $http eq 'HTTP/1.1') {
                $self->error('Wrong method or http version');
                return;
            }

            $self->resource_name($resource_name);

            $self->state('fields');
        }
        elsif ($line ne '') {
            my ($name, $value) = split ': ' => $line => 2;

            $self->fields->{$name} = $value;
        }
        else {
            $self->state('body');
        }
    }

    if ($self->state eq 'body') {
        if ($self->key1 && $self->key2) {
            return 1 if length $chunk < 8;

            if (length $chunk > 8) {
                $self->error('Body is too long');
                return;
            }

            $self->challenge($chunk);
        }
        else {
            $self->version(75);
        }

        return $self->done if $self->_finalize;

        $self->error('Not a valid request');
        return;
    }

    return 1;
}

sub host {
    my $self = shift;
    my $host = shift;

    return $self->{fields}->{'Host'} unless defined $host;

    $self->{fields}->{'Host'} = $host;

    return $self;
}

sub origin { shift->{fields}->{'Origin'} }

sub upgrade    { shift->{fields}->{'Upgrade'} }
sub connection { shift->{fields}->{'Connection'} }

sub number1 { shift->_number('number1', 'key1', @_) }
sub number2 { shift->_number('number2', 'key2', @_) }

sub key1 { shift->_key('key1' => @_) }
sub key2 { shift->_key('key2' => @_) }

sub to_string {
    my $self = shift;

    my $string = '';

    Carp::croak(qq/resource_name is required/)
      unless defined $self->resource_name;
    $string .= "GET " . $self->resource_name . " HTTP/1.1\x0d\x0a";

    $string .= "Upgrade: WebSocket\x0d\x0a";
    $string .= "Connection: Upgrade\x0d\x0a";

    Carp::croak(qq/Host is required/) unless defined $self->host;
    $string .= "Host: " . $self->host . "\x0d\x0a";

    my $origin = $self->origin ? $self->origin : 'http://' . $self->host;
    $string .= "Origin: " . $origin . "\x0d\x0a";

    if ($self->version > 75) {
        $self->_generate_keys;

        $string .= 'Sec-WebSocket-Key1: ' . $self->key1 . "\x0d\x0a";
        $string .= 'Sec-WebSocket-Key2: ' . $self->key2 . "\x0d\x0a";

        $string .= 'Content-Length: ' . length($self->challenge) . "\x0d\x0a";
    }

    # TODO cookies

    $string .= "\x0d\x0a";

    $string .= $self->challenge if $self->version > 75;

    return $string;
}

sub _number {
    my $self = shift;
    my ($name, $key, $value) = @_;

    if (defined $value) {
        $self->{$name} = $value;
        return $self;
    }

    return $self->{$name} if defined $self->{$name};

    return $self->{$name} ||= $self->_extract_number($self->$key);
}

sub _key {
    my $self  = shift;
    my $name  = shift;
    my $value = shift;

    return $self->{fields}->{"Sec-WebSocket-" . ucfirst($name)}
      ||= delete $self->{$name}
      unless defined $value;

    $self->{fields}->{"Sec-WebSocket-" . ucfirst($name)} = $value;

    return $self;
}

sub _generate_keys {
    my $self = shift;

    unless ($self->key1) {
        my ($number, $key) = $self->_generate_key;
        $self->number1($number);
        $self->key1($key);
    }

    unless ($self->key2) {
        my ($number, $key) = $self->_generate_key;
        $self->number2($number);
        $self->key2($key);
    }

    $self->challenge($self->_generate_challenge) unless $self->challenge;

    return $self;
}

sub _generate_key {
    my $self = shift;

    # A random integer from 1 to 12 inclusive
    my $spaces = int(rand(12)) + 1;

    # The largest integer not greater than 4,294,967,295 divided by spaces
    my $max = int(4_294_967_295 / $spaces);

    # A random integer from 0 to $max inclusive
    my $number = int(rand($max + 1));

    # The result of multiplying $number and $spaces together
    my $product = $number * $spaces;

    # A string consisting of $product, expressed in base ten
    my $key = "$product";

    # Insert between one and twelve random characters from the ranges U+0021
    # to U+002F and U+003A to U+007E into $key at random positions.
    my $random_characters = int(rand(12)) + 1;

    for (1 .. $random_characters) {

        # From 0 to the last position
        my $random_position = int(rand(length($key) + 1));

        # Random character
        my $random_character = chr(
              int(rand(2))
            ? int(rand(0x2f - 0x21 + 1)) + 0x21
            : int(rand(0x7e - 0x3a + 1)) + 0x3a
        );

        # Insert random character at random position
        substr $key, $random_position, 0, $random_character;
    }

    # Insert $spaces U+0020 SPACE characters into $key at random positions
    # other than the start or end of the string.
    for (1 .. $spaces) {

        # From 1 to the last-1 position
        my $random_position = int(rand(length($key) - 1)) + 1;

        # Insert
        substr $key, $random_position, 0, ' ';
    }

    return ($number, $key);
}

sub _generate_challenge {
    my $self = shift;

    # A string consisting of eight random bytes (or equivalently, a random 64
    # bit integer encoded in big-endian order).
    my $challenge = '';

    $challenge .= chr(int(rand(256))) for 1 .. 8;

    return $challenge;
}

sub _finalize {
    my $self = shift;

    return unless $self->upgrade    && $self->upgrade    eq 'WebSocket';
    return unless $self->connection && $self->connection eq 'Upgrade';
    return unless $self->origin;
    return unless $self->host;

    my $cookie = $self->_build_cookie;
    if (my $cookies = $cookie->parse($self->fields->{Cookie})) {
        $self->{cookies} = $cookies;
    }

    return 1;
}

sub _build_cookie { Protocol::WebSocket::Cookie::Request->new }

1;
__END__

=head1 NAME

Protocol::WebSocket::Request - WebSocket Request

=head1 SYNOPSIS

    # Constructor
    my $req = Protocol::WebSocket::Request->new(
        fields        => {Host => 'example.com'},
        resource_name => '/demo'
    );
    $req->to_string; # GET /demo HTTP/1.1
                     # Upgrade: WebSocket
                     # Connection: Upgrade
                     # Host: example.com
                     # Origin: http://example.com
                     # Sec-WebSocket-Key1: 32 0  3lD& 24+<    i u4  8! -6/4
                     # Sec-WebSocket-Key2: 2q 4  2  54 09064
                     #
                     # x#####

    # Parser
    my $req = Protocol::WebSocket::Request->new;
    $req->parse("GET /demo HTTP/1.1\x0d\x0a");
    $req->parse("Upgrade: WebSocket\x0d\x0a");
    $req->parse("Connection: Upgrade\x0d\x0a");
    $req->parse("Host: example.com\x0d\x0a");
    $req->parse("Origin: http://example.com\x0d\x0a");
    $req->parse(
        "Sec-WebSocket-Key1: 18x 6]8vM;54 *(5:  {   U1]8  z [  8\x0d\x0a");
    $req->parse(
        "Sec-WebSocket-Key2: 1_ tx7X d  <  nw  334J702) 7]o}` 0\x0d\x0a");
    $req->parse("\x0d\x0aTm[K T2u");

=head1 DESCRIPTION

Construct or parse a WebSocket request.

=head1 ATTRIBUTES

=head2 C<host>

=head2 C<key1>

=head2 C<key2>

=head2 C<number1>

=head2 C<number2>

=head2 C<origin>

=head2 C<resource_name>

=head1 METHODS

=head2 C<new>

Create a new L<Protocol::WebSocket::Request> instance.

=head2 C<parse>

Parse a WebSocket request.

=head2 C<to_string>

Construct a WebSocket request.

=head2 C<connection>

=head2 C<cookies>

=head2 C<upgrade>

=cut
