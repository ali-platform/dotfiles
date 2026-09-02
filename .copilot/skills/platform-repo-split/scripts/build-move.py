#!/usr/bin/env python3
"""Build the destination stack state that adopts one component's resources.

The legacy project and each per-component project sit on separate DIY backends,
so `pulumi state move` cannot reach across them. This transplants the
component-owned resources out of a legacy stack export and into the (empty)
destination stack export, rewriting them into the destination project.

Nothing is uploaded. The caller imports the result and gates on `pulumi preview`
showing tag-only updates.

    pulumi stack export --stack {stack} > legacy.json          # in the legacy repo
    pulumi stack export --stack {stack} > dest.json            # in the component repo
    build-move.py --legacy-project one-platform-reference \
                  --component api --stack dev \
                  --legacy legacy.json --dest dest.json --out moved.json
    pulumi stack import --stack {stack} --file moved.json      # in the component repo
"""
import argparse
import copy
import json
import sys


def component_resource_names(legacy_project: str, component: str, stack: str) -> set[str]:
    """Top-level resources the component owns. Children are pulled in by parent."""
    return {
        f'k8s-app-{legacy_project}-{component}-{stack}',
        f'eso-{legacy_project}-{component}-{stack}',
        f'{component}-appconfig-application',
        f'{component}-appconfig-environment',
        f'{component}-appconfig-profile',
        f'{component}-appconfig-strategy',
        f'{component}-rds-policy-attachment',
    }


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument('--legacy-project', required=True, help='e.g. one-platform-reference')
    p.add_argument('--component', required=True)
    p.add_argument('--stack', required=True)
    p.add_argument('--legacy', required=True, help='legacy stack export')
    p.add_argument('--dest', required=True, help='destination stack export')
    p.add_argument('--out', required=True)
    args = p.parse_args()

    src_project = args.legacy_project
    dst_project = f'{src_project}-{args.component}'

    legacy = json.load(open(args.legacy))
    dest = json.load(open(args.dest))
    src_resources = legacy['deployment']['resources']
    dst_resources = dest['deployment']['resources']

    src_stack_urn = next(r['urn'] for r in src_resources if r['type'] == 'pulumi:pulumi:Stack')
    dst_stack_urn = next(r['urn'] for r in dst_resources if r['type'] == 'pulumi:pulumi:Stack')

    if len(dst_resources) != 1:
        sys.exit(f'ERROR destination stack is not empty: {len(dst_resources)} resources')

    wanted = component_resource_names(src_project, args.component, args.stack)
    selected = {r['urn'] for r in src_resources if r['urn'].split('::')[-1] in wanted}
    if not selected:
        sys.exit('ERROR selected nothing; check --legacy-project/--component/--stack')

    while True:
        children = {r['urn'] for r in src_resources
                    if r.get('parent') in selected and r['urn'] not in selected}
        if not children:
            break
        selected |= children

    # The destination stack has no provider of its own yet, so the legacy default
    # aws provider is carried across and retargeted at the destination repo's
    # ghr-* role and repo URL. Skip this and the first update shows a provider diff.
    provider = copy.deepcopy(next(
        r for r in src_resources
        if r['type'] == 'pulumi:providers:aws' and r['urn'].split('::')[-1].startswith('default_')
    ))
    provider['inputs'] = {
        k: (v.replace(f'platform-{src_project}', f'platform-{dst_project}')
            if isinstance(v, str) else v)
        for k, v in provider['inputs'].items()
    }

    def rewrite(value):
        if isinstance(value, str):
            return value.replace(f'::{src_project}::', f'::{dst_project}::')
        if isinstance(value, list):
            return [rewrite(v) for v in value]
        if isinstance(value, dict):
            return {k: rewrite(v) for k, v in value.items()}
        return value

    def port(resource):
        r = copy.deepcopy(resource)
        for field in ('urn', 'provider', 'deletedWith',
                      'dependencies', 'aliases', 'propertyDependencies'):
            if field in r:
                r[field] = rewrite(r[field])
        if r.get('parent') == src_stack_urn:
            r['parent'] = dst_stack_urn
        elif 'parent' in r:
            r['parent'] = rewrite(r['parent'])
        return r

    ported = [port(provider)] + [port(r) for r in src_resources if r['urn'] in selected]

    # Edges pointing at resources that stay behind (postgresql-policy-{c}) must be
    # dropped, not rewritten: the destination program references that policy by
    # constructed ARN and has no dependency on it. Left in place, the import
    # refuses with "refers to missing resource" and suggests --force. Do not.
    kept = {r['urn'] for r in ported}
    for r in ported:
        for field in ('dependencies', 'deletedWith'):
            if isinstance(r.get(field), list):
                for d in [d for d in r[field] if d not in kept]:
                    print(f'  dropped {field}: {r["urn"].split("::")[-1]} -> {d.split("::")[-1]}')
                r[field] = [d for d in r[field] if d in kept]
        if r.get('propertyDependencies'):
            r['propertyDependencies'] = {k: [d for d in v if d in kept]
                                         for k, v in r['propertyDependencies'].items()}

    out = copy.deepcopy(dest)
    # The moved resources' secrets were sealed with the legacy stack's data key.
    # Both stacks wrap their key with the same KMS master key, so carrying the
    # source provider block lets the destination read them; the next update
    # re-seals with the destination's own key. Without this the import fails
    # with "cipher: message authentication failed".
    out['deployment']['secrets_providers'] = legacy['deployment']['secrets_providers']
    out['deployment']['resources'] = dst_resources + ported

    dangling = [r['urn'] for r in ported
                if r.get('parent', dst_stack_urn) != dst_stack_urn and r['parent'] not in kept]
    if dangling:
        sys.exit(f'ERROR dangling parent refs: {dangling}')

    json.dump(out, open(args.out, 'w'), indent=2)

    print(f'{args.component}/{args.stack}: {len(ported) - 1} resources + carried provider')
    for r in ported:
        print(f'  {r["type"]:<55} {r["urn"].split("::")[-1]}')
    print(f'\nwrote {args.out}')
    print('Now: pulumi stack import --stack '
          f'{args.stack} --file {args.out}   (in the component repo)')


if __name__ == '__main__':
    main()
