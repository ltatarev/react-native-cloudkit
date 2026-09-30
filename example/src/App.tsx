import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import {
  Button,
  SafeAreaView,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  View,
} from 'react-native';
import {
  acceptInvite,
  ackInbox,
  addListener,
  CloudKitError,
  configure,
  deleteRecords,
  drainInbox,
  getCurrentUserId,
  isAvailable,
  leaveShare,
  listZones,
  presentManageSheet,
  presentShareSheet,
  saveRecords,
  stopSharing,
  syncNow,
} from '@ltatarev/react-native-cloudkit';
import type {
  Invite,
  PrivateZoneRef,
  SyncStatus,
  ZoneRef,
} from '@ltatarev/react-native-cloudkit';
import {
  useAccountStatus,
  useShare,
  useSyncStatus,
} from '@ltatarev/react-native-cloudkit/react';
import type { Note } from './notesStore';
import {
  applyEvents,
  dropNote,
  loadNotes,
  putNote,
  saveNotes,
  zoneKey,
} from './notesStore';

/*
 * A test bed, not a product. It proves the package with made-up record
 * types (`Note`, `Task`) in its own container, so they never reach an app's
 * schema. See example/TESTING.md for the two-device checklist.
 */

const CONTAINER_ID = 'iCloud.com.ltatarev.cloudkit-example';
const MY_NOTES: PrivateZoneRef = { name: 'notes', scope: 'private' };

function describeStatus(status: SyncStatus): string {
  switch (status.state) {
    case 'syncing':
      return 'Syncing…';
    case 'waiting':
      return `Waiting to sync: ${status.reason}${
        status.retryAfter ? ` (${status.retryAfter}s)` : ''
      }`;
    default:
      return status.lastSyncedAt
        ? `Synced ${status.lastSyncedAt.toLocaleTimeString()}`
        : 'Idle';
  }
}

export default function App() {
  const available = isAvailable();
  const account = useAccountStatus();
  const status = useSyncStatus();
  const [userId, setUserId] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [ready, setReady] = useState(false);
  const [notes, setNotes] = useState<Record<string, Note>>({});
  const [zones, setZones] = useState<ZoneRef[]>([MY_NOTES]);
  const [zone, setZone] = useState<ZoneRef>(MY_NOTES);
  const [invite, setInvite] = useState<Invite | null>(null);
  const notesRef = useRef(notes);
  notesRef.current = notes;

  const report = useCallback((caught: unknown) => {
    setError(
      caught instanceof CloudKitError
        ? `${caught.code}: ${caught.message}`
        : String(caught)
    );
  }, []);

  const commit = useCallback(async (next: Record<string, Note>) => {
    setNotes(next);
    await saveNotes(next);
  }, []);

  const refreshZones = useCallback(async () => {
    const shared = await listZones('shared');

    setZones([MY_NOTES, ...shared.map((info) => info.zone)]);
  }, []);

  /* Drain, apply, commit, then ack: an event is only acked once it is saved. */
  const drain = useCallback(async () => {
    const events = await drainInbox();

    if (events.length === 0) return;
    const applied = applyEvents(notesRef.current, events);

    await commit(applied.notes);
    await ackInbox(events.map((event) => event.id));
    for (const resetZone of applied.resend) {
      const records = Object.values(applied.notes)
        .filter((note) => zoneKey(note.zone) === zoneKey(resetZone))
        .map((note) => ({
          fields: { body: note.body, title: note.title },
          recordName: note.recordName,
          recordType: 'Note',
          zone: note.zone,
        }));

      await saveRecords(records);
    }
    await refreshZones();
  }, [commit, refreshZones]);

  useEffect(() => {
    if (!available) return undefined;
    let live = true;

    (async () => {
      try {
        setNotes(await loadNotes());
        await configure({
          containerId: CONTAINER_ID,
          recordTypes: {
            Note: { fields: { body: 'string', title: 'string' } },
            Task: {
              conflict: 'serverWins',
              fields: { done: 'bool', dueAt: 'date', title: 'string' },
            },
          },
        });
        if (!live) return;
        setReady(true);
        setUserId(await getCurrentUserId());
        await refreshZones();
        await drain();
      } catch (caught) {
        report(caught);
      }
    })();

    const unsubscribers = [
      addListener('inboxChanged', () => {
        drain().catch(report);
      }),
      addListener('inviteReceived', setInvite),
      addListener('shareAccepted', (info) => {
        setZone(info.zone);
        refreshZones().catch(report);
      }),
      addListener('accountChanged', (change) => {
        setUserId(change.kind === 'signOut' ? null : change.userId);
      }),
    ];

    return () => {
      live = false;
      unsubscribers.forEach((unsubscribe) => unsubscribe());
    };
  }, [available, drain, refreshZones, report]);

  const shown = useMemo(
    () =>
      Object.values(notes).filter(
        (note) => zoneKey(note.zone) === zoneKey(zone)
      ),
    [notes, zone]
  );

  const saveNote = useCallback(
    async (note: Note) => {
      try {
        await commit(putNote(notesRef.current, note));
        await saveRecords([
          {
            fields: { body: note.body, title: note.title },
            recordName: note.recordName,
            recordType: 'Note',
            zone: note.zone,
          },
        ]);
      } catch (caught) {
        report(caught);
      }
    },
    [commit, report]
  );

  const addNote = useCallback(() => {
    saveNote({
      body: '',
      createdBy: userId,
      modifiedBy: userId,
      recordName: `note-${Date.now().toString(36)}`,
      title: 'New note',
      zone,
    });
  }, [saveNote, userId, zone]);

  const removeNote = useCallback(
    async (note: Note) => {
      try {
        await commit(dropNote(notesRef.current, note.zone, note.recordName));
        await deleteRecords([{ recordName: note.recordName, zone: note.zone }]);
      } catch (caught) {
        report(caught);
      }
    },
    [commit, report]
  );

  if (!available) {
    return (
      <SafeAreaView style={styles.screen}>
        <Text style={styles.line}>isAvailable: false</Text>
      </SafeAreaView>
    );
  }

  return (
    <SafeAreaView style={styles.screen}>
      <ScrollView contentContainerStyle={styles.content}>
        <Text style={styles.line}>isAvailable: {String(available)}</Text>
        <Text style={styles.line}>account: {account ?? '…'}</Text>
        <Text style={styles.line}>user id: {userId ?? '—'}</Text>
        <Text style={styles.banner}>{describeStatus(status)}</Text>
        {error ? <Text style={styles.error}>{error}</Text> : null}

        {invite ? (
          <View style={styles.card}>
            <Text style={styles.title}>
              Invite: {invite.title ?? 'Untitled'} from{' '}
              {invite.ownerName ?? 'someone'} ({invite.participantCount})
            </Text>
            <Button
              title="Join"
              onPress={() => {
                acceptInvite(invite.token)
                  .then(() => setInvite(null))
                  .catch(report);
              }}
            />
            <Button title="Not now" onPress={() => setInvite(null)} />
          </View>
        ) : null}

        <View style={styles.row}>
          <Button
            disabled={!ready}
            title="Sync now"
            onPress={() => {
              syncNow().catch(report);
            }}
          />
          <Button disabled={!ready} title="Add note" onPress={addNote} />
        </View>

        <View style={styles.row}>
          {zones.map((item) => (
            <Button
              key={zoneKey(item)}
              title={item.scope === 'private' ? 'My notes' : item.name}
              onPress={() => setZone(item)}
            />
          ))}
        </View>

        <ZoneSharing zone={zone} onError={report} />

        {shown.map((note) => (
          <View key={note.recordName} style={styles.card}>
            <TextInput
              style={styles.input}
              value={note.title}
              onChangeText={(title) => saveNote({ ...note, title })}
            />
            <TextInput
              multiline
              style={styles.input}
              value={note.body}
              onChangeText={(body) => saveNote({ ...note, body })}
            />
            <Text style={styles.meta}>
              createdBy {note.createdBy ?? '—'} · modifiedBy{' '}
              {note.modifiedBy ?? '—'}
            </Text>
            <Button title="Delete" onPress={() => removeNote(note)} />
          </View>
        ))}
      </ScrollView>
    </SafeAreaView>
  );
}

function ZoneSharing({
  onError,
  zone,
}: {
  zone: ZoneRef;
  onError: (error: unknown) => void;
}) {
  const { refresh, share } = useShare(zone);

  return (
    <View style={styles.card}>
      <View style={styles.row}>
        {zone.scope === 'private' ? (
          <Button
            title="Share"
            onPress={() => {
              presentShareSheet(zone, {
                permission: 'readWrite',
                title: 'Example notes',
              })
                .then(refresh)
                .catch(onError);
            }}
          />
        ) : null}
        {share ? (
          <Button
            title="Manage"
            onPress={() => {
              presentManageSheet(zone).then(refresh).catch(onError);
            }}
          />
        ) : null}
        {share && zone.scope === 'private' ? (
          <Button
            title="Stop sharing"
            onPress={() => {
              stopSharing(zone).then(refresh).catch(onError);
            }}
          />
        ) : null}
        {zone.scope === 'shared' ? (
          <Button
            title="Leave"
            onPress={() => {
              leaveShare(zone).catch(onError);
            }}
          />
        ) : null}
      </View>
      {share?.participants.map((participant) => (
        <Text key={participant.id} style={styles.meta}>
          {participant.name ?? participant.userId ?? participant.id} ·{' '}
          {participant.role} · {participant.permission} · {participant.status}
          {participant.isCurrentUser ? ' (you)' : ''}
        </Text>
      ))}
    </View>
  );
}

const styles = StyleSheet.create({
  banner: { backgroundColor: '#fff3cd', padding: 8 },
  card: {
    borderColor: '#ccc',
    borderRadius: 8,
    borderWidth: 1,
    gap: 4,
    padding: 8,
  },
  content: { gap: 8, padding: 16 },
  error: { color: '#b00020' },
  input: { borderColor: '#ddd', borderWidth: 1, padding: 6 },
  line: { fontFamily: 'Menlo' },
  meta: { color: '#666', fontSize: 12 },
  row: { flexDirection: 'row', flexWrap: 'wrap', gap: 8 },
  screen: { flex: 1 },
  title: { fontWeight: '600' },
});
