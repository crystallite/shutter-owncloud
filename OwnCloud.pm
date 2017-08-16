#! /usr/bin/env perl

package OwnCloud;

use lib $ENV{'SHUTTER_ROOT'} . '/share/shutter/resources/modules';

use utf8;
use strict;
use POSIX qw/setlocale/;
use File::Basename;
use URI::Escape;
use Locale::gettext;
use Glib qw/TRUE FALSE/;

use Shutter::Upload::Shared;
our @ISA = qw(Shutter::Upload::Shared);

my $d = Locale::gettext->domain("shutter-plugins");
$d->dir( $ENV{'SHUTTER_INTL'} );

my %upload_plugin_info = (
    module       => "OwnCloud",
    url          => "https://owncloud.net/",
    registration => "",
    description  => $d->get("Upload screenshots to owncloud storage"),
    supports_anonymous_upload  => FALSE,
    supports_authorized_upload => TRUE,
);

binmode( STDOUT, ":utf8" );
if ( exists $upload_plugin_info{ $ARGV[0] } ) {
    print $upload_plugin_info{ $ARGV[0] };
    exit;
}

#don't touch this
sub new {
    my $class = shift;

#call constructor of super class (host, debug_cparam, shutter_root, gettext_object, main_gtk_window, ua)
    my $self = $class->SUPER::new( shift, shift, shift, shift, shift, shift );

    bless $self, $class;
    return $self;
}

#load some custom modules here (or do other custom stuff)
sub init {
    my $self = shift;

    use HTTP::DAV;
    use XML::XPath;

    return TRUE;
}

sub will_not_clobber {
    my ( $new_file, @existing ) = @_;

    my %existing = map { $_ => 1 } @existing;
    my ( $filename, $ext ) = split /\./, $new_file;
    my $rv    = $new_file;
    my $count = 1;

    while ( $existing{$rv} ) {
        $rv = "$filename-$count" . ( $ext ? ".$ext" : "" );
        ++$count;
    }

    return $rv;
}

#handle
sub upload {
    my ( $self, $upload_filename, $username, $password ) = @_;

    #store as object vars
    $self->{_filename} = $upload_filename;
    $self->{_username} = $username;
    $self->{_password} = $password;

    utf8::encode $upload_filename;
    utf8::encode $password;
    utf8::encode $username;

    my $webdav   = HTTP::DAV->new;
    my $url      = $upload_plugin_info{url} . '/remote.php/webdav';
    my $dir      = 'Screenshots';
    my $basename = uri_escape( basename($upload_filename) );

    #username/password are provided
    if ( $username ne "" && $password ne "" ) {

        eval {
            $webdav->credentials(
                -user => $username,
                -pass => $password,
                -url  => $url,
            );
            unless ( $webdav->open( -url => $url ) ) {
                $self->{_links}{status} = 999;
                die $webdav->message;
            }
        };

        if ($@) {
            $self->{_links}{'status'} = $@;
            return %{ $self->{_links} };
        }
        if ( $self->{_links}{'status'} == 999 ) {
            return %{ $self->{_links} };
        }

    }

    #upload the file
    eval {

        #########################
        #put the upload code here
        #########################

        if ( !$webdav->cwd($dir) ) {
            $webdav->mkcol($dir) and $webdav->cwd($dir)
              or die "Cannot open $dir directory: " . $webdav->message . "\n";
        }
        my $r = $webdav->propfind("")
          or die "Cannot PROPFIND $dir: " . $webdav->message . "\n";

        # if found anything then try not to clobber
        if ( $r->get_resourcelist ) {
            $basename = will_not_clobber( $basename,
                map { basename( $_->get_uri->path ) }
                  $r->get_resourcelist->get_resources );
        }

        $webdav->put(
            -local => $upload_filename,
            -url   => "$url/$dir/$basename"
          )
          or die "Cannot upload to $url/$dir/$basename: "
          . $webdav->message . "\n";

        my $ua   = $webdav->get_user_agent;
        my $resp = $ua->post(
            $upload_plugin_info{url}
              . "/ocs/v1.php/apps/files_sharing/api/v1/shares",
            { path => "$dir/$basename", shareType => 3 }
        );
        $resp->code == 200
          or die "Cannot publish $basename: " . $resp->code . "; ",
          $resp->message . "\n";
        my $xp = XML::XPath->new( xml => $resp->content );

        my $publish_code = $xp->findvalue('/ocs/meta/statuscode');
        my $publish_url  = $xp->findvalue('/ocs/data/url');
        $publish_code->value() == "100"
          or die "Cannot publish $basename: " . "\n";
        $self->{_links}{direct_link} = $publish_url->value();

        $self->{_links}{'status'} = 200;

    };
    if ($@) {
        $self->{_links}{'status'} = $@;
    }

    #and return links
    return %{ $self->{_links} };
}

#you are free to implement some custom subs here, but please make sure they don't interfere with Shutter's subs
#hence, please follow this naming convention: _<provider>_sub (e.g. _imageshack_convert_x_to_y)

1;
