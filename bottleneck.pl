#!/usr/bin/env perl
use Mojolicious::Lite;
use File::Copy;
use XML::DOM::XPath;
use lib '../../Boost-Polygon-Voronoi/blib/lib';
use lib '../../Boost-Polygon-Voronoi/blib/arch';
use Boost::Polygon::Voronoi;
use lib '../../../surfboards/approot/lib';
use Math::MikePath;

my $workingboards = '../../../surfboards/workingboards';
unshift @{ app->static->paths }, $workingboards;


get '/' => sub {
  my $c = shift;
  #$c->render(text => 'Hello World!');
  #return $c->render
} => 'index';

any ['get','post','put'], 'choose_svg/:reqtype' => sub {
    my $c = shift;
    my $m = $c->req->json;
    
    if ($c->stash('reqtype') eq 'file' ) {
        my $f =  $workingboards . '/' .$m->{loc};
        unless (-e $f) {$c->render(json => {"error"=>"nothing","loc" => $f });}
        $f=~/\/([^\/]+)$/ or $c->render(json => {"error" => "couldn't figure file name", "loc" => $m->{loc}});
        my $fn = $1;
        # nah, lets not make a mess in there
        #my $fnc  = './public/'.$fn;
        #my $fncm = $fnc.'.modified';
        my $fnc  = './public/master_copy.svg';
        my $fncm = './public/working_copy.svg';        
        copy($f,$fnc) or $c->render(json => {"error" => "couldn't get copy", "loc" => $m->{loc}});
        copy($fnc,$fncm) or $c->render(json => {"error" => "couldn't make working copy", "loc" => $m->{loc}.'.modified'});
        $c->render(json => {"loc" => '/working_copy.svg'});
    }
    else {
        $c->render(json => {error => "nope", loc => $m->{loc}});
    }
};

any ['get','put','patch','post'], 'selectors' => sub {
    my $c = shift;
    my $m;
    
    if ($c->req->json) {$m=$c->req->json;}
    else {$m = {'selector1'=>$c->req->param('selector1'),
                'selector2'=>$c->req->param('selector2'),
                'selector3'=>$c->req->param('selector3')  };
    }
    
    if (!$m->{selector1} &&!$m->{selector2} && !$m->{selector3}) {
        #$m->{selector1} = '//path[@class = "production_part_notch"]';
        #$c->render(json => {"success" => "but no selectors"});
    }
    

    my $p=XML::DOM::Parser->new('KeepCDATA' => 1);
    my $d=$p->parsefile('./public/master_copy.svg');
    $d->setXMLDecl($d->createXMLDecl('1.0', 'UTF-8', 'yes'));
    
    my @nodes;

    # get nodes requested by selectors
    if (defined $m->{selector1} && $m->{selector1} =~ /^\//) {push @nodes, $d->findnodes($m->{selector1});}
    if (defined $m->{selector2} && $m->{selector2} =~ /^\//) {push @nodes, $d->findnodes($m->{selector2});}
    if (defined $m->{selector3} && $m->{selector3} =~ /^\//) {push @nodes, $d->findnodes($m->{selector3});}
    
    if (!@nodes) {
        $c->render(json => {"success" => "no nodes matched selectors"});
        return;
    }
    
    my $bpv = new Boost::Polygon::Voronoi::builder;
    my $scale = 1000;
    
    my $svg='';
    
    my ($minx,$maxx,$miny,$maxy);
    
    foreach my $node (grep {$_->getAttribute('d')} @nodes) { 
        # extract path, and turn it into something 
        # medial axis code can use
        warn "node\n";
        my $mp = Math::MikePath->newlite($node->getAttribute('d'),0.00001);
        my $psegs = $mp->{pathSegments};
        my @exploded = ([@{$psegs->[0]->{p1}}] ,
                        (map {warn ref($psegs->[$_]),' [',join(', ',@{$psegs->[$_]->{p2}}),"]\n";ref($psegs->[$_])=~/(line|close)/i ? [@{$psegs->[$_]->{p2}}] : $mp->dimensionalCurve(0.1,0.5,0.5,[$_,$_])} (0 .. $#$psegs))
                        );

        my @exploded_scaled;
        my %dups;
        @exploded_scaled = grep {$dups{$_->[0].','.$_->[1]}++;$dups{$_->[0].','.$_->[1]} < 2}
            map {$_->[0]=int($_->[0]*$scale);$_->[1]=int($_->[1]*$scale);$_}
            @exploded;
        my ($thisminx,$thismaxx) = (sort {$a<=>$b}  map {$_->[0]} @exploded_scaled)[0,-1];
        my ($thisminy,$thismaxy) = (sort {$a<=>$b}  map {$_->[1]} @exploded_scaled)[0,-1];
        if (!defined $minx || $minx>$thisminx) {$minx=$thisminx;}
        if (!defined $miny || $miny>$thisminy) {$miny=$thisminy;}
        if (!defined $maxx || $maxx<$thismaxx) {$maxx=$thismaxx;}
        if (!defined $maxy || $maxy<$thismaxy) {$maxy=$thismaxy;}

        my @exploded_segs;
        for (my $i = -1;$i<$#exploded_scaled;$i++) {
            push @exploded_segs, [ (@{$exploded_scaled[$i]}[0,1],@{$exploded_scaled[$i+1]}[0,1])];
        }

        #warn "insert ",join(", ",@these),"\n";

        warn "insert $minx,$maxx\n";
        #$bpv->insert_segment(@$_) for @exploded_scaled[0 .. 2];

        open(AHH,'>','public/working_segs.pl');
        print AHH 'our $working_segs = [',"\n";
        print AHH '['.join(',',@$_).'],'."\n" for @exploded_segs;
        print AHH "];\n\$working_segs_scale=$scale;\n";
        close AHH;
        copy('public/working_segs.pl','../../working_segs.pl');
        #$c->render(text => 'nothing: '.scalar(@exploded_scaled));
        #return;

        $bpv->insert_segment(@$_) for @exploded_segs;
        my $ma = $bpv->medial_axis();
        $bpv->clear();
        warn "done\n";
        
        my $edge = '';


        my @edges = map {[[$_->vertex0()->x()/$scale,$_->vertex0()->y()/$scale],
                          [$_->vertex1()->x()/$scale,$_->vertex1()->y()/$scale]]}
                    grep {$_ 
                          && $_->vertex0 
                          && $_->vertex0->x() 
                          && $_->vertex1 
                          && $_->vertex1->x()
                          && $_->is_internal
                          && $_->is_finite
                         }
                    @{$ma->edges()};

        $edge.= '<line x1="'.($_->[0]->[0]).'" '.
                       'y1="'.($_->[0]->[1]).'" '.
                       'x2="'.($_->[1]->[0]).'" '.
                       'y2="'.($_->[1]->[1]).'" '.
                       'stroke="blue" stroke-width="0.1"/>'
        for (@edges);
        
        $svg.=$node->toString()."\n".$edge."\n";

        #$c->render(json => [scalar(@{$ma->edges}) , $bpv->num_edges]);
        
        
        # run edge filter with current options, if there are options
        # get svg output from that and insert as sibling right after
        # run to paths stuff with current options
        # get svg output from that and insert as sibling right after
        # save modified svg doc to working_copy.svg
    
    }
    
    $c->render(text => ''.
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'."\n".
        '<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" '.
        'x="0" y="0" '.
        'viewBox="'.($minx/$scale)        .' '.($miny/$scale).' '.
                    (($maxx-$minx)/$scale).' '.(($maxy-$miny)/$scale).'" '.
        'width="100%" height="100%" '.
        '>'."\n".


        'viewBox="'.($minx/$scale).' '.($miny/$scale).' '.
        (($maxx-$minx)/$scale).' '.(($maxy-$miny)/$scale).'" '.
        'preserveAspectRatio="xMidYMid meet" '.
        '><style>'.'</style>'.
        $svg .
        '<path d="'.'" stroke-width="5" stroke="lime" fill="none" />'.
        '</svg>'
    );

    #my $d=$p->printToFile('./public/working_copy.svg');
    
    
};

app->start;
