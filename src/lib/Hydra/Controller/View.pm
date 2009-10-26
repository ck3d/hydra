package Hydra::Controller::View;

use strict;
use warnings;
use base 'Catalyst::Controller';
use Hydra::Helper::Nix;
use Hydra::Helper::CatalystUtils;


sub getView {
    my ($c, $projectName, $viewName) = @_;
    
    my $project = $c->model('DB::Projects')->find($projectName);
    notFound($c, "Project $projectName doesn't exist.") if !defined $project;
    $c->stash->{project} = $project;

    (my $view) = $c->model('DB::Views')->find($projectName, $viewName);
    notFound($c, "View $viewName doesn't exist.") if !defined $view;
    $c->stash->{view} = $view;

    (my $primaryJob) = $view->viewjobs->search({isprimary => 1});
    #die "View $viewName doesn't have a primary job." if !defined $primaryJob;

    my $jobs = [$view->viewjobs->search({},
        {order_by => ["isprimary DESC", "job", "attrs"]})];

    $c->stash->{jobs} = $jobs;

    return ($project, $view, $primaryJob, $jobs);
}


sub updateView {
    my ($c, $view) = @_;
    
    my $viewName = trim $c->request->params->{name};
    error($c, "Invalid view name: $viewName")
        unless $viewName =~ /^[[:alpha:]][\w\-]*$/;
    
    $view->update(
        { name => $viewName
        , description => trim $c->request->params->{description} });

    $view->viewjobs->delete_all;

    foreach my $param (keys %{$c->request->params}) {
        next unless $param =~ /^job-(\d+)-name$/;
        my $baseName = $1;

        my $name = trim $c->request->params->{"job-$baseName-name"};
        my $description = trim $c->request->params->{"job-$baseName-description"};
        my $attrs = trim $c->request->params->{"job-$baseName-attrs"};

        $name =~ /^([\w\-]+):([\w\-]+)$/ or error($c, "Invalid job name: $name");
        my $jobsetName = $1;
        my $jobName = $2;

        error($c, "Jobset `$jobsetName' doesn't exist.")
            unless $view->project->jobsets->find({name => $jobsetName});

        # !!! We could check whether the job exists, but that would
        # require the scheduler to have seen the job, which may not be
        # the case.
        
        $view->viewjobs->create(
            { jobset => $jobsetName
            , job => $jobName
            , description => $description
            , attrs => $attrs
            , isprimary => $c->request->params->{"primary"} eq $baseName ? 1 : 0
            });
    }

    error($c, "There must be one primary job.")
        if $view->viewjobs->search({isprimary => 1})->count != 1;
}


sub view : Chained('/') PathPart('view') CaptureArgs(2) {
    my ($self, $c, $projectName, $viewName) = @_;
    my ($project, $view, $primaryJob, $jobs) = getView($c, $projectName, $viewName);
    $c->stash->{project} = $project;
    $c->stash->{view} = $view;
    $c->stash->{primaryJob} = $primaryJob;
    $c->stash->{jobs} = $jobs;
}


sub view_view : Chained('view') PathPart('') Args(0) {
    my ($self, $c) = @_;

    $c->stash->{template} = 'view.tt';

    my $resultsPerPage = 10;
    my $page = int($c->req->param('page')) || 1;

    my @results = ();
    push @results, getViewResult($_, $c->stash->{jobs}) foreach
        getPrimaryBuildsForView($c->stash->{project}, $c->stash->{primaryJob}, $page, $resultsPerPage);

    $c->stash->{baseUri} = $c->uri_for($self->action_for("view_view"), $c->req->captures);
    $c->stash->{results} = [@results];
    $c->stash->{page} = $page;
    $c->stash->{totalResults} = getPrimaryBuildTotal($c->stash->{project}, $c->stash->{primaryJob});
    $c->stash->{resultsPerPage} = $resultsPerPage;
}


sub edit : Chained('view') PathPart('edit') Args(0) {
    my ($self, $c) = @_;
    requireProjectOwner($c, $c->stash->{project});
    $c->stash->{template} = 'edit-view.tt';
}

    
sub submit : Chained('view') PathPart('submit') Args(0) {
    my ($self, $c) = @_;
    requireProjectOwner($c, $c->stash->{project});
    txn_do($c->model('DB')->schema, sub {
        updateView($c, $c->stash->{view});
    });
    $c->res->redirect($c->uri_for($self->action_for("view_view"), $c->req->captures));
}

    
sub delete : Chained('view') PathPart('delete') Args(0) {
    my ($self, $c) = @_;
    requireProjectOwner($c, $c->stash->{project});
    txn_do($c->model('DB')->schema, sub {
        $c->stash->{view}->delete;
    });
    $c->res->redirect($c->uri_for($c->controller('Project')->action_for('view'),
        [$c->stash->{project}->name]));
}

    
sub latest : Chained('view') PathPart('latest') {
    my ($self, $c, @args) = @_;
    
    # Redirect to the latest result in the view in which every build
    # is successful.
    my $latest = getLatestSuccessfulViewResult(
        $c->stash->{project}, $c->stash->{primaryJob}, $c->stash->{jobs});
    error($c, "This view set has no successful results yet.") if !defined $latest;
    $c->res->redirect($c->uri_for($self->action_for("view_view"), $c->req->captures, $latest->id, @args));
}


sub result : Chained('view') PathPart('') {
    my ($self, $c, $id, @args) = @_;
    
    $c->stash->{template} = 'view-result.tt';

    # Note: we don't actually check whether $id is a primary build,
    # but who cares?
    my $primaryBuild = $c->stash->{project}->builds->find($id,
        { join => 'resultInfo',
        , '+select' => ["resultInfo.releasename", "resultInfo.buildstatus"]
        , '+as' => ["releasename", "buildstatus"] })
        or error($c, "Build $id doesn't exist.");

    $c->stash->{result} = getViewResult($primaryBuild, $c->stash->{jobs});

    # Provide a redirect to the specified job of this view result.
    # !!!  This isn't uniquely defined if there are multiple jobs with
    # the same name (e.g. builds for different platforms).  However,
    # this mechanism is primarily to allow linking to resources of
    # which there is only one build, such as the manual of the latest
    # view result.
    if (scalar @args != 0) {
        my $jobName = shift @args;
        (my $build, my @others) = grep { $_->{job}->job eq $jobName } @{$c->stash->{result}->{jobs}};
        notFound($c, "View doesn't have a job named `$jobName'")
            unless defined $build;
        error($c, "Job `$jobName' isn't unique.") if @others;
        return $c->res->redirect($c->uri_for($c->controller('Build')->action_for('view_build'),
            [$build->{build}->id], @args));
    }
}


1;