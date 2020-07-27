#!/usr/bin/perl -w
#
# This script is glue for wiring together the different providers (AWS, GCP, GKE)
# to a benchmarking script.
#
# Calling this script creates a cluster using the provider, runs the benchmark,
# and deletes the cluster upon completion.
###################################################################################
use strict;
use warnings;
use Data::Dumper qw(Dumper);
use BenchmarkResults qw(writeResults extractResults);

my $provider = shift(@ARGV);
my $benchmark = shift(@ARGV);

sub usage {
    die "Usage: ./run-benchmark.pl <provider> <benchmark>\n";
}

if (!$provider) {
    usage();
} elsif (!$benchmark) {
    usage();
}

# Trim trailing slash if present.
$provider =~ s/\/$//;
$benchmark =~ s/\/$//;

# Generate some random tag we can use for logging.
my $tag = `head -c 3 /dev/urandom | md5 | head -c 5`;
my $date = `date '+%Y-%m-%dT%H:%M:%S'`;
chomp($date);
# Given provider "provider/aws" we want providerShort=aws
my @p1 = split(/\//, $provider);
my $providerShort = $p1[scalar(@p1) - 1];
my @p2 = split(/\//, $benchmark);
my $benchmarkShort = $p2[scalar(@p2) - 1];
my $cwd = `pwd`;
chomp($cwd);
my $logfile = "$cwd/runlog-benchmark-$providerShort-$benchmarkShort-$tag-$date.log";

sub createStack {
    my $script = shift(@_);
    print "Creating stack...\n";

    my $cmd = "cd \"$provider\" && /bin/bash create.sh " . '2>&1 | tee -a "' . $logfile . '"';
    print "Running create stack command $cmd";
    my $startTime = time();
    my $output = `$cmd`;
    my $exitCode = $?;
    my $endTime = time();
    print $output;
    
    $output =~ m/^NEO4J_URI=([^\s]+)$/m;
    my $uri = $1;
    $output =~ m/^STACK_NAME=([^\s]+)$/m;
    my $stack = $1;
    $output =~ m/^NEO4J_PASSWORD=([^\s]+)$/m;
    my $password = $1;
    $output =~ m/^RUN_ID=([^\s]+)$/m;
    my $runID = $1;

    if (!$uri || !$stack || !$password) {
        print STDERR $output;
        die "Create cluster script failed to return ip, name, or password: $uri, $stack, $password\n";
    }

    my %provisioningProperties = (
        "PROV_TIME" => ($endTime - $startTime),
        "PROV_EXIT" => $exitCode
    );
    writeResults($logfile, \%provisioningProperties);

    return (
        "uri" => $uri,
        "stack" => $stack,
        "password" => $password,
        "run_id" => $runID
    );
}

sub deleteStack {
    my $script = shift(@_);
    my $hashref = shift(@_);

    print "Deleting stack...\n";

    my $cmd = "cd \"$provider\" && /bin/bash delete.sh " . $hashref->{"stack"} . ' 2>&1 | tee -a "' . $logfile . '"';
    print "Executing $cmd\n";
    my $startTime = time();
    print `$cmd`;
    my $exitCode = $?;
    my $endTime = time();

    my %deprovProperties = (
        "DEPROV_TIME" => ($endTime - $startTime),
        "DEPROV_EXIT" => $exitCode
    );
    writeResults($logfile, \%deprovProperties);
}

sub checkLatency {
    my $log = shift(@_);
    my $hashref = shift(@_);

    my $uri = $hashref->{"uri"};
    my $password = $hashref->{"password"};

    my $cmd = "node latency.js -a '". $uri . "' -p '" . $password . "' " . '2>&1 | tee -a "' . $logfile . '"';
    my $output = `$cmd`;
    my $exitCode = $?;

    print "Latency output:\n";
    print $output;

    if ($exitCode == 0) {
        return "Good!";
    }

    return undef;
}

sub runBenchmark {
    my $dir = shift(@_);
    my $script = shift(@_);
    my $hashref = shift(@_);

    my $uri = $hashref->{"uri"};
    my $password = $hashref->{"password"};

    if (!$uri || !$password) {
        print STDERR "Skipping benchmark run: missing URI or password from stack reference\n";
        return undef;
    }

    my $cmd = "cd \"$benchmark\" && /bin/bash ./benchmark.sh \"$uri\" \"$password\" " . '2>&1 | tee -a "' . $logfile . '"';
    print "Running benchmark ... $cmd\n";
    my $startTime = time();
    my $output = `$cmd`;
    my $exitCode = $?; # Did benchmark script succeed or fail?
    my $endTime = time();

    print "OVERALL BENCHMARK OUTPUT:\n";
    print $output;

    my $logShort = $logfile;
    $logShort =~ s/$cwd//; # Don't save complete path.

    return (
        "EXECUTION_TIME" => ($endTime - $startTime),
        "EXIT_CODE" => $exitCode,
        "TAG" => $tag,
        "LOG_FILE" => $logShort,
        "PROVIDER" => $providerShort,
        "BENCHMARK" => $benchmarkShort,
        "DATE" => $date
    );
}

sub main {
    # These lines are API requirements of what providers and benchmarks are.
    my $createCluster = "$provider/create.sh";
    my $deleteCluster = "$provider/delete.sh";
    my $benchmarkScript = "$benchmark/benchmark.sh";

    if (!(-f $createCluster)) {
        die "Invalid provider $provider: this provider does not know how to create an instance\n";
    } elsif (!(-f $deleteCluster)) {
        die "Invalid provider $provider: this provider does not know how to delete an instance\n";
    } elsif (!(-f $benchmarkScript)) {
        die "Invalid benchmark $benchmark: this benchmark does not have a run script\n";
    }

    my %hash = createStack($createCluster);
    print Dumper(\%hash);

    print "Checking deploy latencies to make sure stack is working\n";
    my $allOK = checkLatency($logfile, \%hash);

    if (!defined($allOK)) {
        print "Latency probe failed, destroying deploy\n";
        deleteStack($deleteCluster, \%hash);
        return undef;
    }

    my %properties = runBenchmark($benchmark, $benchmarkScript, \%hash);
    writeResults($logfile, \%properties);

    print "Results extraction phase.\n";
    my %results = extractResults($logfile);
    print Dumper(\%results);

    deleteStack($deleteCluster, \%hash);
    print "Done";
}

main();