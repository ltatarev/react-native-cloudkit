import { CloudKitError, toCloudKitError } from '../errors';
import {
  decodeFields,
  encodeFields,
  fromBridgeInboxEvent,
  fromBridgeShare,
  fromBridgeZone,
  parseAccountChange,
  parseSyncStatus,
  toBridgeZone,
} from '../mapping';
import { assertValidName, assertValidRecordTypes } from '../validate';

const NOTE = {
  conflict: 'fieldMerge' as const,
  fields: {
    body: 'string' as const,
    dueAt: 'date' as const,
    rank: 'int' as const,
  },
};

describe('zones', () => {
  it('keeps the owner of a shared zone and drops it for a private one', () => {
    expect(
      toBridgeZone({ name: 'list-1', owner: '_abc', scope: 'shared' })
    ).toEqual({
      name: 'list-1',
      owner: '_abc',
      scope: 'shared',
    });
    expect(
      fromBridgeZone({ name: 'library', owner: 'x', scope: 'private' })
    ).toEqual({
      name: 'library',
      scope: 'private',
    });
  });
});

describe('fields', () => {
  it('sends a date as epoch milliseconds and reads it back as a Date', () => {
    const due = new Date(1_700_000_000_000);
    const json = encodeFields({ body: 'hi', dueAt: due, rank: 2, tags: ['a'] });

    expect(JSON.parse(json)).toEqual({
      body: 'hi',
      dueAt: 1_700_000_000_000,
      rank: 2,
      tags: ['a'],
    });
    expect(decodeFields(JSON.parse(json), NOTE)).toEqual({
      body: 'hi',
      dueAt: due,
      rank: 2,
      tags: ['a'],
    });
  });

  it('leaves a number alone when the config does not call it a date', () => {
    expect(decodeFields({ dueAt: 5 }, undefined)).toEqual({ dueAt: 5 });
  });
});

describe('fromBridgeInboxEvent', () => {
  const zone = { name: 'notes', scope: 'private' };

  it('maps an upsert with its meta', () => {
    const event = fromBridgeInboxEvent(
      {
        id: '7',
        kind: 'upsert',
        payloadJson: JSON.stringify({
          createdAt: 1,
          createdBy: '_u1',
          fields: { body: 'x', dueAt: 10 },
          modifiedAt: 2,
          modifiedBy: '_u2',
          recordName: 'n1',
          recordType: 'Note',
          zone,
        }),
      },
      { Note: NOTE }
    );

    expect(event).toEqual({
      id: '7',
      kind: 'upsert',
      record: {
        createdAt: new Date(1),
        createdBy: '_u1',
        fields: { body: 'x', dueAt: new Date(10) },
        modifiedAt: new Date(2),
        modifiedBy: '_u2',
        recordName: 'n1',
        recordType: 'Note',
        zone: { name: 'notes', scope: 'private' },
      },
    });
  });

  it('maps a zone deletion with its reason', () => {
    expect(
      fromBridgeInboxEvent(
        {
          id: '8',
          kind: 'zoneDeleted',
          payloadJson: JSON.stringify({
            reason: 'shareEnded',
            zone: { name: 'list-1', owner: '_o', scope: 'shared' },
          }),
        },
        {}
      )
    ).toEqual({
      id: '8',
      kind: 'zoneDeleted',
      reason: 'shareEnded',
      zone: { name: 'list-1', owner: '_o', scope: 'shared' },
    });
  });

  it('drops a kind it does not know', () => {
    expect(
      fromBridgeInboxEvent({ id: '9', kind: 'future', payloadJson: '{}' }, {})
    ).toBeUndefined();
  });
});

describe('events', () => {
  it('reads each sync state', () => {
    expect(parseSyncStatus('{"state":"syncing"}')).toEqual({
      state: 'syncing',
    });
    expect(parseSyncStatus('{"state":"idle","lastSyncedAt":5}')).toEqual({
      lastSyncedAt: new Date(5),
      state: 'idle',
    });
    expect(parseSyncStatus('{"state":"idle"}')).toEqual({
      lastSyncedAt: null,
      state: 'idle',
    });
    expect(
      parseSyncStatus(
        '{"state":"waiting","reason":"throttled","retryAfter":30}'
      )
    ).toEqual({ reason: 'throttled', retryAfter: 30, state: 'waiting' });
    expect(parseSyncStatus('{"state":"waiting","reason":"???"}')).toEqual({
      reason: 'other',
      state: 'waiting',
    });
  });

  it('reads each account change', () => {
    expect(parseAccountChange('{"kind":"signIn","userId":"_a"}')).toEqual({
      kind: 'signIn',
      userId: '_a',
    });
    expect(parseAccountChange('{"kind":"signOut"}')).toEqual({
      kind: 'signOut',
    });
    expect(
      parseAccountChange('{"kind":"switchAccounts","userId":"_b"}')
    ).toEqual({ kind: 'switchAccounts', userId: '_b' });
  });

  it('reads a share with an undiscoverable participant', () => {
    expect(
      fromBridgeShare({
        isOwner: true,
        participants: [
          {
            id: 'p1',
            isCurrentUser: false,
            permission: 'readOnly',
            role: 'privateUser',
            status: 'accepted',
          },
        ],
        publicPermission: 'none',
        zone: { name: 'list-1', scope: 'private' },
      })
    ).toEqual({
      isOwner: true,
      participants: [
        {
          id: 'p1',
          isCurrentUser: false,
          name: null,
          permission: 'readOnly',
          role: 'privateUser',
          status: 'accepted',
          userId: null,
        },
      ],
      publicPermission: 'none',
      url: null,
      zone: { name: 'list-1', scope: 'private' },
    });
  });
});

describe('validation', () => {
  it('refuses a name CloudKit refuses', () => {
    expect(() => assertValidName('zone', '_owner')).toThrow(CloudKitError);
    expect(() => assertValidName('zone', '')).toThrow(CloudKitError);
    expect(() => assertValidName('record', 'x'.repeat(256))).toThrow(
      CloudKitError
    );
    expect(() => assertValidName('record', 'naïve')).toThrow(CloudKitError);
    expect(() => assertValidName('record', 'take-_abc-movie-1')).not.toThrow();
  });

  it('refuses the reserved prefix and a field that starts with a digit', () => {
    expect(() =>
      assertValidRecordTypes({ Note: { fields: { RNCK_x: 'string' } } })
    ).toThrow(/reserved|RNCK_/);
    expect(() =>
      assertValidRecordTypes({ Note: { fields: { '1x': 'string' } } })
    ).toThrow(CloudKitError);
    expect(() => assertValidRecordTypes({ Note: NOTE })).not.toThrow();
  });
});

describe('toCloudKitError', () => {
  it('reads the code a native rejection carries', () => {
    const error = toCloudKitError(
      new Error('[RNCK:recordTooLarge] Record n1 is 1.2 MB')
    );

    expect(error.code).toBe('recordTooLarge');
    expect(error.message).toBe('Record n1 is 1.2 MB');
  });

  it('calls anything else unknown', () => {
    expect(toCloudKitError(new Error('boom')).code).toBe('unknown');
    expect(toCloudKitError('boom').code).toBe('unknown');
  });
});
