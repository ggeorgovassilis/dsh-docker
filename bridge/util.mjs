/**
 * Small helpers shared by the bridge modules.
 *
 * @module dsh-api-runtime/util
 */

/** Bound a string so log lines cannot grow without limit. */
export function logSafePreview(value, max = 200) {
  if (typeof value !== 'string') return String(value).slice(0, max);
  const oneLine = value.replace(/[\r\n\t]+/g, ' ');
  return oneLine.length > max ? `${oneLine.slice(0, max)}…` : oneLine;
}
