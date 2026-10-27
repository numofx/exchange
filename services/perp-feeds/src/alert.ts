/**
 * Posts to ALERT_WEBHOOK_URL in the shape the ops scripts already use ({text, content}, which Slack
 * and Discord both read). Each alert key is held back for `cooldownMs` after it fires, so a refusal
 * that lasts an hour pages a few times rather than sixty. `tag` heads every message: a second
 * instance of a keeper (a v2 series) names itself, since its alert keys are the first one's.
 */
export type Alerter = (key: string, message: string) => Promise<void>;

export function createAlerter(
  webhookUrl: string | undefined,
  cooldownMs = 15 * 60_000,
  now: () => number = Date.now,
  fetchImpl: typeof fetch = fetch,
  tag = 'perp-feeds',
): Alerter {
  const lastSent = new Map<string, number>();

  return async (key, message) => {
    console.error(`[alert] ${key}: ${message}`);
    const previous = lastSent.get(key);
    if (previous !== undefined && now() - previous < cooldownMs) return;
    lastSent.set(key, now());
    if (!webhookUrl) return;
    try {
      const response = await fetchImpl(webhookUrl, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ text: `[${tag}] ${message}`, content: `[${tag}] ${message}` }),
        signal: AbortSignal.timeout(10_000),
      });
      // A 2xx means the webhook took it, not that anyone read it; a non-2xx means nobody will.
      if (!response.ok) console.error(`[alert] webhook returned ${response.status} for ${key}`);
    } catch (error) {
      console.error(`[alert] webhook failed for ${key}: ${(error as Error).message}`);
    }
  };
}
