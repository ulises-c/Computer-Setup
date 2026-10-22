"""The policy travels with its pages, never in a separately replaced sidecar."""
from datetime import date, datetime
import json
import re
import time

POLICY_TABLE = 'wiki_policy'
POLICY_COLUMNS = ('policy',)
POLICY_SCHEMA = 'CREATE TABLE wiki_policy (policy TEXT NOT NULL)'
POLICY_KEYS = {'version', 'mode', 'effectiveDate', 'asOf', 'deployment', 'expiresAt', 'status'}
METADATA_KEYS = {'version', 'protocolRevision', 'historicalContentDate', 'historicalContentDateSource',
                 'contentIdentity', 'observedAt', 'confidence'}
TTL = 600


def valid_date(value):
    if not isinstance(value, str) or not re.fullmatch(r'[0-9]{4}-[0-9]{2}-[0-9]{2}', value):
        return False
    try:
        date.fromisoformat(value)
        return True
    except ValueError:
        return False


def timestamp(value, *, utc=False):
    zone = 'Z' if utc else r'(?:Z|[+-](?:0[0-9]|1[0-9]|2[0-3]):[0-5][0-9])'
    if not isinstance(value, str) or not re.fullmatch(r'[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]{1,6})?' + zone, value):
        raise ValueError('Invalid wiki policy timestamp')
    return datetime.fromisoformat(value.replace('Z', '+00:00')).timestamp()


def validate_policy(policy):
    now = time.time()
    if not isinstance(policy, dict) or set(policy) != POLICY_KEYS:
        raise ValueError('Invalid wiki policy fields')
    if type(policy['version']) is not int or policy['version'] != 1 or policy['mode'] not in ('automatic', 'override'):
        raise ValueError('Invalid wiki policy mode or version')
    if not valid_date(policy['effectiveDate']) or policy['status'] not in ('fresh', 'missing-or-invalid', 'expired'):
        raise ValueError('Unavailable wiki policy date or status')
    deployment = policy['deployment']
    expires = None
    if deployment is None:
        if policy['expiresAt'] is not None or policy['status'] != 'missing-or-invalid':
            raise ValueError('Invalid wiki policy deployment')
    else:
        if not isinstance(deployment, dict) or set(deployment) != METADATA_KEYS:
            raise ValueError('Invalid wiki policy metadata')
        if (type(deployment['version']) is not int or deployment['version'] != 1
                or type(deployment['protocolRevision']) is not int or not 0 < deployment['protocolRevision'] <= 2**53 - 1
                or not valid_date(deployment['historicalContentDate'])
                or deployment['historicalContentDateSource'] != 'content-readme'
                or not isinstance(deployment['contentIdentity'], str) or not deployment['contentIdentity'].strip()
                or re.search(r'[\x00-\x1f\x7f]', deployment['contentIdentity'])
                or deployment['confidence'] != 'declared-target'):
            raise ValueError('Invalid wiki policy metadata')
        observed = timestamp(deployment['observedAt'])
        expires = timestamp(policy['expiresAt'], utc=True)
        if observed > now or not observed < expires <= observed + TTL or expires > now + TTL:
            raise ValueError('Invalid wiki policy lifetime')
        if policy['status'] == 'missing-or-invalid':
            raise ValueError('Invalid wiki policy status')
    if policy['mode'] == 'automatic':
        if (deployment is None or expires is None or policy['asOf'] is not None or policy['status'] != 'fresh'
                or policy['effectiveDate'] != deployment['historicalContentDate'] or now >= expires):
            raise ValueError('Expired or unknown automatic wiki policy')
    elif not valid_date(policy['asOf']) or policy['asOf'] != policy['effectiveDate']:
        raise ValueError('Invalid wiki policy override')
    return policy


def read_policy(db):
    columns = list(db.execute('PRAGMA table_xinfo(wiki_policy)'))
    if len(columns) != 1 or tuple(columns[0][1:4]) != ('policy', 'TEXT', 1) or columns[0][6]:
        raise ValueError('Invalid wiki policy schema')
    rows = db.execute('SELECT policy FROM wiki_policy LIMIT 2').fetchall()
    if len(rows) != 1 or not isinstance(rows[0][0], str) or len(rows[0][0]) > 16384:
        raise ValueError('Invalid wiki policy row')
    return validate_policy(json.loads(rows[0][0]))
