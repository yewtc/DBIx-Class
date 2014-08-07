package # hide from PAUSE
  DBIx::Class::_Util;

use warnings;
use strict;

# Temporary - tempextlib
use namespace::clean;
BEGIN {
  require Module::Runtime;
  require File::Spec;

  # There can be only one of these, make sure we get the bundled part and
  # *not* something off the site lib
  for (qw(
    DBIx::Class::SQLMaker
    SQL::Abstract
    SQL::Abstract::Test
  )) {
    if ($INC{Module::Runtime::module_notional_filename($_)}) {
      die "\nUnable to continue - a part of the bundled templib contents "
        . "was already loaded (likely an older version from CPAN). "
        . "Make sure that @{[ __PACKAGE__ ]} is loaded before $_\n\n"
      ;
    }
  }

  our ($HERE) = File::Spec->rel2abs(
    File::Spec->catdir( (File::Spec->splitpath(__FILE__))[1], '_TempExtlib' )
  ) =~ /^(.*)$/; # screw you, taint mode

  die "TempExtlib $HERE does not seem to exist - perhaps you need to run `perl Makefile.PL` in the DBIC checkout?\n"
    unless -d $HERE;

  unshift @INC, $HERE;
}

use constant SPURIOUS_VERSION_CHECK_WARNINGS => ($] < 5.010 ? 1 : 0);

BEGIN {
  package # hide from pause
    DBIx::Class::_ENV_;

  use Config;

  use constant {

    # but of course
    BROKEN_FORK => ($^O eq 'MSWin32') ? 1 : 0,

    BROKEN_GOTO => ($] < '5.008003') ? 1 : 0,

    HAS_ITHREADS => $Config{useithreads} ? 1 : 0,

    # ::Runmode would only be loaded by DBICTest, which in turn implies t/
    DBICTEST => eval { DBICTest::RunMode->is_author } ? 1 : 0,

    # During 5.13 dev cycle HELEMs started to leak on copy
    # add an escape for these perls ON SMOKERS - a user will still get death
    PEEPEENESS => ( eval { DBICTest::RunMode->is_smoker } && ($] >= 5.013005 and $] <= 5.013006) ),

    SHUFFLE_UNORDERED_RESULTSETS => $ENV{DBIC_SHUFFLE_UNORDERED_RESULTSETS} ? 1 : 0,

    ASSERT_NO_INTERNAL_WANTARRAY => $ENV{DBIC_ASSERT_NO_INTERNAL_WANTARRAY} ? 1 : 0,

    ASSERT_NO_INTERNAL_INDIRECT_CALLS => $ENV{DBIC_ASSERT_NO_INTERNAL_INDIRECT_CALLS} ? 1 : 0,

    IV_SIZE => $Config{ivsize},

    OS_NAME => $^O,
  };

  if ($] < 5.009_005) {
    require MRO::Compat;
    constant->import( OLD_MRO => 1 );
  }
  else {
    require mro;
    constant->import( OLD_MRO => 0 );
  }
}

# FIXME - this is not supposed to be here
# Carp::Skip to the rescue soon
use DBIx::Class::Carp '^DBIx::Class|^DBICTest';

use Carp 'croak';
use Scalar::Util qw(weaken blessed reftype);
use List::Util qw(first);

# DO NOT edit away without talking to riba first, he will just put it back
# BEGIN pre-Moo2 import block
BEGIN {
  my $initial_fatal_bits = (${^WARNING_BITS}||'') & $warnings::DeadBits{all};
  local $ENV{PERL_STRICTURES_EXTRA} = 0;
  require Sub::Quote; Sub::Quote->import('quote_sub');
  ${^WARNING_BITS} &= ( $initial_fatal_bits | ~ $warnings::DeadBits{all} );
}
sub qsub ($) { goto &quote_sub }  # no point depping on new Moo just for this
# END pre-Moo2 import block

use base 'Exporter';
our @EXPORT_OK = qw(
  sigwarn_silencer modver_gt_or_eq
  fail_on_internal_wantarray fail_on_internal_call
  refdesc refcount hrefaddr is_exception
  quote_sub qsub perlstring
  UNRESOLVABLE_CONDITION
);

use constant UNRESOLVABLE_CONDITION => \ '1 = 0';

sub sigwarn_silencer ($) {
  my $pattern = shift;

  croak "Expecting a regexp" if ref $pattern ne 'Regexp';

  my $orig_sig_warn = $SIG{__WARN__} || sub { CORE::warn(@_) };

  return sub { &$orig_sig_warn unless $_[0] =~ $pattern };
}

sub perlstring ($) { q{"}. quotemeta( shift ). q{"} };

sub hrefaddr ($) { sprintf '0x%x', &Scalar::Util::refaddr||0 }

sub refdesc ($) {
  croak "Expecting a reference" if ! length ref $_[0];

  # be careful not to trigger stringification,
  # reuse @_ as a scratch-pad
  sprintf '%s%s(0x%x)',
    ( defined( $_[1] = blessed $_[0]) ? "$_[1]=" : '' ),
    reftype $_[0],
    Scalar::Util::refaddr($_[0]),
  ;
}

sub refcount ($) {
  croak "Expecting a reference" if ! length ref $_[0];

  require B;
  # No tempvars - must operate on $_[0], otherwise the pad
  # will count as an extra ref
  B::svref_2object($_[0])->REFCNT;
}

sub is_exception ($) {
  my $e = $_[0];

  # this is not strictly correct - an eval setting $@ to undef
  # is *not* the same as an eval setting $@ to ''
  # but for the sake of simplicity assume the following for
  # the time being
  return 0 unless defined $e;

  my ($not_blank, $suberror);
  {
    local $@;
    eval {
      $not_blank = ($e ne '') ? 1 : 0;
      1;
    } or $suberror = $@;
  }

  if (defined $suberror) {
    if (length (my $class = blessed($e) )) {
      carp_unique( sprintf(
        'External exception class %s implements partial (broken) overloading '
      . 'preventing its instances from being used in simple ($x eq $y) '
      . 'comparisons. Given Perl\'s "globally cooperative" exception '
      . 'handling this type of brokenness is extremely dangerous on '
      . 'exception objects, as it may (and often does) result in silent '
      . '"exception substitution". DBIx::Class tries to work around this '
      . 'as much as possible, but other parts of your software stack may '
      . 'not be even aware of this. Please submit a bugreport against the '
      . 'distribution containing %s and in the meantime apply a fix similar '
      . 'to the one shown at %s, in order to ensure your exception handling '
      . 'is saner application-wide. What follows is the actual error text '
      . "as generated by Perl itself:\n\n%s\n ",
        $class,
        $class,
        'http://v.gd/DBIC_overload_tempfix/',
        $suberror,
      ));

      # workaround, keeps spice flowing
      $not_blank = ("$e" ne '') ? 1 : 0;
    }
    else {
      # not blessed yet failed the 'ne'... this makes 0 sense...
      # just throw further
      die $suberror
    }
  }

  return $not_blank;
}

sub modver_gt_or_eq ($$) {
  my ($mod, $ver) = @_;

  croak "Nonsensical module name supplied"
    if ! defined $mod or ! length $mod;

  croak "Nonsensical minimum version supplied"
    if ! defined $ver or $ver =~ /[^0-9\.\_]/;

  local $SIG{__WARN__} = sigwarn_silencer( qr/\Qisn't numeric in subroutine entry/ )
    if SPURIOUS_VERSION_CHECK_WARNINGS;

  croak "$mod does not seem to provide a version (perhaps it never loaded)"
    unless $mod->VERSION;

  local $@;
  eval { $mod->VERSION($ver) } ? 1 : 0;
}

{
  my $list_ctx_ok_stack_marker;

  sub fail_on_internal_wantarray () {
    return if $list_ctx_ok_stack_marker;

    if (! defined wantarray) {
      croak('fail_on_internal_wantarray() needs a tempvar to save the stack marker guard');
    }

    my $cf = 1;
    while ( ( (caller($cf+1))[3] || '' ) =~ / :: (?:

      # these are public API parts that alter behavior on wantarray
      search | search_related | slice | search_literal

        |

      # these are explicitly prefixed, since we only recognize them as valid
      # escapes when they come from the guts of CDBICompat
      CDBICompat .*? :: (?: search_where | retrieve_from_sql | retrieve_all )

    ) $/x ) {
      $cf++;
    }

    my ($fr, $want, $argdesc);
    {
      package DB;
      $fr = [ caller($cf) ];
      $want = ( caller($cf-1) )[5];
      $argdesc = ref $DB::args[0]
        ? DBIx::Class::_Util::refdesc($DB::args[0])
        : 'non '
      ;
    };

    if (
      $want and $fr->[0] =~ /^(?:DBIx::Class|DBICx::)/
    ) {
      DBIx::Class::Exception->throw( sprintf (
        "Improper use of %s instance in list context at %s line %d\n\n    Stacktrace starts",
        $argdesc, @{$fr}[1,2]
      ), 'with_stacktrace');
    }

    my $mark = [];
    weaken ( $list_ctx_ok_stack_marker = $mark );
    $mark;
  }
}

sub fail_on_internal_call {
  my ($fr, $argdesc);
  {
    package DB;
    $fr = [ caller(1) ];
    $argdesc = ref $DB::args[0]
      ? DBIx::Class::_Util::refdesc($DB::args[0])
      : undef
    ;
  };

  if (
    $argdesc
      and
    $fr->[0] =~ /^(?:DBIx::Class|DBICx::)/
      and
    $fr->[1] !~ /\b(?:CDBICompat|ResultSetProxy)\b/  # no point touching there
  ) {
    DBIx::Class::Exception->throw( sprintf (
      "Illegal internal call of indirect proxy-method %s() with argument %s: examine the last lines of the proxy method deparse below to determine what to call directly instead at %s on line %d\n\n%s\n\n    Stacktrace starts",
      $fr->[3], $argdesc, @{$fr}[1,2], ( $fr->[6] || do {
        require B::Deparse;
        no strict 'refs';
        B::Deparse->new->coderef2text(\&{$fr->[3]})
      }),
    ), 'with_stacktrace');
  }
}

1;
