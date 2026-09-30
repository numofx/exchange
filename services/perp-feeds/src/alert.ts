/**
 * Posts to ALERT_WEBHOOK_URL in the shape the ops scripts already use ({text, content}, which Slack
 * and Discord both read). Each alert key is held back for `cooldownMs` after it fires, so a refusal
 * that lasts an hour pages a few times rather than sixty.
 */
export type Alerter = (key: string, message: string) => Promise<void>;

export function createAlerter(
  webhookUrl: string | undefined,
  cooldownMs = 15 * 60_000,
  now: () => number = Date.now,
  fetchImpl: typeof fetch = fetch,
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
        body: JSON.stringify({ text: `[perp-feeds] ${message}`, content: `[perp-feeds] ${message}` }),
        signal: AbortSignal.timeout(10_000),
      });
      // A 2xx means the webhook took it, not that anyone read it; a non-2xx means nobody will.
      if (!response.ok) console.error(`[alert] webhook returned ${response.status} for ${key}`);
    } catch (error) {
      console.error(`[alert] webhook failed for ${key}: ${(error as Error).message}`);
    }
  };
}
