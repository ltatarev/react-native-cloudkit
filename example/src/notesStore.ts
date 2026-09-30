import AsyncStorage from '@react-native-async-storage/async-storage';
import type {
  InboxEvent,
  RecordMeta,
  ZoneRef,
} from '@ltatarev/react-native-cloudkit';

/**
 * The example app's own database: notes in AsyncStorage. The package is not
 * the source of truth. It only moves changes in and out of iCloud, and this
 * file applies what arrives.
 */

export type Note = {
  zone: ZoneRef;
  recordName: string;
  title: string;
  body: string;
  createdBy: string | null;
  modifiedBy: string | null;
};

const KEY = 'example.notes';

export function zoneKey(zone: ZoneRef): string {
  return zone.scope === 'shared'
    ? `shared/${zone.owner}/${zone.name}`
    : `private/${zone.name}`;
}

function noteKey(zone: ZoneRef, recordName: string): string {
  return `${zoneKey(zone)}/${recordName}`;
}

export async function loadNotes(): Promise<Record<string, Note>> {
  const raw = await AsyncStorage.getItem(KEY);

  return raw ? (JSON.parse(raw) as Record<string, Note>) : {};
}

export async function saveNotes(notes: Record<string, Note>): Promise<void> {
  await AsyncStorage.setItem(KEY, JSON.stringify(notes));
}

export function putNote(
  notes: Record<string, Note>,
  note: Note
): Record<string, Note> {
  return { ...notes, [noteKey(note.zone, note.recordName)]: note };
}

export function dropNote(
  notes: Record<string, Note>,
  zone: ZoneRef,
  recordName: string
): Record<string, Note> {
  const next = { ...notes };

  delete next[noteKey(zone, recordName)];

  return next;
}

/**
 * Applies inbox events to the notes. `zoneDeleted` follows the README's
 * table: `deleted` and `shareEnded` drop the zone's notes here (a real app
 * offers "Keep a copy" for `shareEnded`), `purged` keeps them, and
 * `encryptedDataReset` keeps them and asks the caller to save them again.
 */
export function applyEvents(
  notes: Record<string, Note>,
  events: InboxEvent[]
): { notes: Record<string, Note>; resend: ZoneRef[] } {
  let next = notes;
  const resend: ZoneRef[] = [];

  for (const event of events) {
    switch (event.kind) {
      case 'upsert': {
        const { record } = event;

        if (record.recordType !== 'Note') break;
        next = putNote(next, toNote(record));
        break;
      }
      case 'delete':
        next = dropNote(next, event.ref.zone, event.ref.recordName);
        break;
      case 'zoneDeleted':
        if (event.reason === 'deleted' || event.reason === 'shareEnded') {
          const prefix = `${zoneKey(event.zone)}/`;

          next = Object.fromEntries(
            Object.entries(next).filter(([key]) => !key.startsWith(prefix))
          );
        }
        if (event.reason === 'encryptedDataReset') resend.push(event.zone);
        break;
      default:
        break;
    }
  }

  return { notes: next, resend };
}

function toNote(
  record: RecordMeta & {
    zone: ZoneRef;
    recordName: string;
    fields: Record<string, unknown>;
  }
): Note {
  return {
    body: typeof record.fields.body === 'string' ? record.fields.body : '',
    createdBy: record.createdBy,
    modifiedBy: record.modifiedBy,
    recordName: record.recordName,
    title: typeof record.fields.title === 'string' ? record.fields.title : '',
    zone: record.zone,
  };
}
