/** Schema v1 (docs/telemetry-schema.md). Rejeita chave desconhecida: um campo novo não entra sem passar por aqui. */

export const MODEL_FAMILIES = [
  'WH-1000XM6', 'WH-1000XM5', 'WH-CH720N', 'ULT WEAR',
  'WF-1000XM6', 'WF-1000XM5', 'WF-1000XM4', 'WF-C710N', 'WF-C700N', 'WF-C510', 'WF-C500',
  'LinkBuds Clip', 'LinkBuds Open', 'LinkBuds S', 'LinkBuds', 'other',
];

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const DATE = /^\d{4}-\d{2}-\d{2}$/;
const VERSION = /^\d{1,3}\.\d{1,3}(\.\d{1,3})?$/;
const SOURCES = ['panel', 'controlCenter', 'hotkey', 'intent', 'externalChange'];
const TRIGGERS = ['call', 'focus', 'app', 'wifi', 'shortcut'];
const TOP = ['v', 'installId', 'date', 'appVersion', 'macOSMajor', 'arch', 'deviceModelFamily', 'activeDay',
  'manualModeChanges', 'modeChangesBySource', 'automation', 'panelOpens'];
const AUTOMATION = ['enabled', 'trialDay', 'triggersFired', 'overridesManual'];

/** O app só envia dias fechados, e descarta depois de 3. Margem de um dia por causa dos fusos. */
const DAYS_BACK = 4;
const DAYS_AHEAD = 1;
const DAY = 86_400_000;

export interface Packet {
  v: 1;
  installId: string;
  date: string;
  appVersion: string;
  macOSMajor: number;
  arch: string;
  deviceModelFamily: string | null;
  activeDay: boolean;
  manualModeChanges: number;
  modeChangesBySource: Record<string, number>;
  automation: { enabled: boolean; trialDay: number | null; triggersFired: Record<string, number>; overridesManual: number };
  panelOpens: number;
}

const isObject = (x: unknown): x is Record<string, unknown> => typeof x === 'object' && x !== null && !Array.isArray(x);
const hasExactly = (o: Record<string, unknown>, keys: string[]) =>
  Object.keys(o).length === keys.length && keys.every((k) => Object.hasOwn(o, k));
const isCounter = (x: unknown) => Number.isInteger(x) && (x as number) >= 0 && (x as number) <= 50;
const areCounters = (x: unknown, keys: string[]) =>
  isObject(x) && hasExactly(x, keys) && keys.every((k) => isCounter(x[k]));

function isRecentDate(value: string, now: Date): boolean {
  if (!DATE.test(value)) return false;
  const time = Date.parse(`${value}T00:00:00Z`);
  if (Number.isNaN(time) || new Date(time).toISOString().slice(0, 10) !== value) return false;
  const today = Date.parse(`${now.toISOString().slice(0, 10)}T00:00:00Z`);
  return time >= today - DAYS_BACK * DAY && time <= today + DAYS_AHEAD * DAY;
}

export function isPacket(x: unknown, now: Date): x is Packet {
  if (!isObject(x) || !hasExactly(x, TOP)) return false;
  const a = x.automation;
  return x.v === 1
    && typeof x.installId === 'string' && UUID.test(x.installId)
    && typeof x.date === 'string' && isRecentDate(x.date, now)
    && typeof x.appVersion === 'string' && VERSION.test(x.appVersion)
    && Number.isInteger(x.macOSMajor) && (x.macOSMajor as number) >= 14 && (x.macOSMajor as number) <= 99
    && (x.arch === 'arm64' || x.arch === 'x86_64')
    && (x.deviceModelFamily === null || MODEL_FAMILIES.includes(x.deviceModelFamily as string))
    && typeof x.activeDay === 'boolean'
    && isCounter(x.manualModeChanges)
    && areCounters(x.modeChangesBySource, SOURCES)
    && isCounter(x.panelOpens)
    && isObject(a) && hasExactly(a, AUTOMATION)
    && typeof a.enabled === 'boolean'
    && (a.trialDay === null || (Number.isInteger(a.trialDay) && (a.trialDay as number) >= 0 && (a.trialDay as number) <= 365))
    && areCounters(a.triggersFired, TRIGGERS)
    && isCounter(a.overridesManual);
}
