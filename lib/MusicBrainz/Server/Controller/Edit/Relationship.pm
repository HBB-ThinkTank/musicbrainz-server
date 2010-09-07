package MusicBrainz::Server::Controller::Edit::Relationship;
use Moose;

BEGIN { extends 'MusicBrainz::Server::Controller' };

use MusicBrainz::Server::Constants qw(
    $EDIT_RELATIONSHIP_DELETE
    $EDIT_RELATIONSHIP_EDIT
    $EDIT_RELATIONSHIP_CREATE
    );
use MusicBrainz::Server::Data::Utils qw( type_to_model );
use MusicBrainz::Server::Edit::Relationship::Delete;
use MusicBrainz::Server::Edit::Relationship::Edit;
use JSON;

sub build_type_info
{
    my ($tree) = @_;

    sub _builder
    {
        my ($root, $info) = @_;

        if ($root->id) {
            my %attrs = map { $_->type_id => [
                defined $_->min ? 0 + $_->min : undef,
                defined $_->max ? 0 + $_->max : undef,
            ] } $root->all_attributes;
            $info->{$root->id} = {
                descr => $root->description,
                attrs => \%attrs,
            };
        }
        foreach my $child ($root->all_children) {
            _builder($child, $info);
        }
    }

    my %type_info;
    _builder($tree, \%type_info);
    return %type_info;
}

sub edit : Local RequireAuth Edit
{
    my ($self, $c) = @_;

    my $id = $c->req->params->{id};
    my $type0 = $c->req->params->{type0};
    my $type1 = $c->req->params->{type1};

    my $rel = $c->model('Relationship')->get_by_id($type0, $type1, $id);
    $c->model('Link')->load($rel);
    $c->model('LinkType')->load($rel->link);
    $c->model('Relationship')->load_entities($rel);

    my $tree = $c->model('LinkType')->get_tree($type0, $type1);
    my %type_info = build_type_info($tree);

    $c->stash(
        root => $tree,
        type_info => JSON->new->latin1->encode(\%type_info),
    );

    my $attr_tree = $c->model('LinkAttributeType')->get_tree();
    $c->stash( attr_tree => $attr_tree );

    my $values = {
        link_type_id => $rel->link->type_id,
        begin_date => $rel->link->begin_date,
        end_date => $rel->link->end_date,
        attrs => {},
    };
    my %attr_multi;
    foreach my $attr ($attr_tree->all_children) {
        $attr_multi{$attr->id} = scalar $attr->all_children;
    }
    foreach my $attr ($rel->link->all_attributes) {
        my $name = $attr->root->name;
        if ($attr_multi{$attr->root->id}) {
            if (exists $values->{attrs}->{$name}) {
                push @{$values->{attrs}->{$name}}, $attr->id;
            }
            else {
                $values->{attrs}->{$name} = [ $attr->id ];
            }
        }
        else {
            $values->{attrs}->{$name} = 1;
        }
    }
    my $form = $c->form( form => 'Relationship', init_object => $values );
    $form->field('link_type_id')->_load_options;

    $c->stash( relationship => $rel );

    if ($c->form_posted && $form->process( params => $c->req->params )) {
        my @attributes;
        foreach my $attr ($attr_tree->all_children) {
            my $value = $form->field('attrs')->field($attr->name)->value;
            if (defined $value) {
                if (scalar $attr->all_children) {
                    push @attributes, @{ $value };
                }
                elsif ($value) {
                    push @attributes, $attr->id;
                }
            }
        }

        my $values = $form->values;
        my $edit = $self->_insert_edit($c, $form,
            edit_type => $EDIT_RELATIONSHIP_EDIT,
            type0             => $type0,
            type1             => $type1,
            relationship      => $rel,
            link_type_id      => $values->{link_type_id},
            begin_date        => $values->{begin_date},
            end_date          => $values->{end_date},
            change_direction  => $values->{direction},
            attributes        => \@attributes
        );

        my $redirect = $c->req->params->{returnto} || $c->uri_for('/search');
        $c->response->redirect($redirect);
        $c->detach;
    }
}

sub create : Local RequireAuth Edit
{
    my ($self, $c) = @_;

    my $qp = $c->req->query_params;
    my ($type0, $type1)         = ($qp->{type0},  $qp->{type1});
    my ($source_gid, $dest_gid) = ($qp->{entity0}, $qp->{entity1});
    if (!$type0 || !$type1 || !$source_gid || !$dest_gid) {
        $c->stash( message => 'Invalid arguments' );
        $c->detach('/error_500');
    }

    my $source_model = $c->model(type_to_model($type0));
    my $dest_model   = $c->model(type_to_model($type1));
    if (!$source_model || !$dest_model) {
        $c->stash( message => 'Invalid entities' );
        $c->detach('/error_500');
    }

    my $source = $source_model->get_by_gid($source_gid);
    my $dest   = $dest_model->get_by_gid($dest_gid);

    if ($source->id == $dest->id) {
        $c->stash( message => 'A relationship requires 2 different entities' );
        $c->detach('/error_500');
    }

    my $tree = $c->model('LinkType')->get_tree($type0, $type1);
    my %type_info = build_type_info($tree);

    $c->stash(
        root      => $tree,
        type_info => JSON->new->latin1->encode(\%type_info),
    );

    my $attr_tree = $c->model('LinkAttributeType')->get_tree();
    $c->stash( attr_tree => $attr_tree );

    my $form = $c->form( form => 'Relationship' );
    $c->stash(
        source => $source, source_type => $type0,
        dest   => $dest,   dest_type   => $type1
    );

    if ($c->form_posted && $form->submitted_and_valid($c->req->params)) {
        my @attributes;
        foreach my $attr ($attr_tree->all_children) {
            my $value = $form->field('attrs')->field($attr->name)->value;
            if (defined $value) {
                if (scalar $attr->all_children) {
                    push @attributes, @{ $value };
                }
                elsif ($value) {
                    push @attributes, $attr->id;
                }
            }
        }

        $self->_insert_edit($c, $form,
            edit_type    => $EDIT_RELATIONSHIP_CREATE,
            type0        => $type0,
            type1        => $type1,
            entity0      => $source->id,
            entity1      => $dest->id,
            begin_date   => $form->field('begin_date')->value,
            end_date     => $form->field('end_date')->value,
            link_type_id => $form->field('link_type_id')->value,
            attributes   => \@attributes,
        );

        my $redirect = $c->controller(type_to_model($type0))->action_for('show');
        $c->response->redirect($c->uri_for_action($redirect, [ $source_gid ]));
        $c->detach;
    }
}

sub delete : Local RequireAuth Edit
{
    my ($self, $c) = @_;

    my $id = $c->req->params->{id};
    my $type0 = $c->req->params->{type0};
    my $type1 = $c->req->params->{type1};

    my $rel = $c->model('Relationship')->get_by_id($type0, $type1, $id);
    $c->model('Link')->load($rel);
    $c->model('LinkType')->load($rel->link);
    $c->model('Relationship')->load_entities($rel);

    my $form = $c->form( form => 'Confirm' );
    $c->stash( relationship => $rel );

    if ($c->form_posted && $form->process( params => $c->req->params )) {
        my $values = $form->values;

        my $edit = $self->_insert_edit($c, $form,
            edit_type    => $EDIT_RELATIONSHIP_DELETE,

            type0        => $type0,
            type1        => $type1,
            relationship => $rel,
        );

        my $redirect = $c->req->params->{returnto} || $c->uri_for('/search');
        $c->response->redirect($redirect);
        $c->detach;
    }

    $c->stash( relationship => $rel );
}

no Moose;
1;

=head1 COPYRIGHT

Copyright (C) 2009 Lukas Lalinsky

This program is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 2 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.

=cut
