/**
 * Posts to the ops webhook.
 *
 * Both keys on purpose: Slack reads `text`, Discord reads `content`. The settlement canary and the
 * ops-box scripts post the same shape, so one webhook serves every sender.
 */
export type PostAlert = (url: string, text: string) => Promise<void>;

export const postAlert: PostAlert = async (url, text) => {
  const response = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ text, content: text }),
    signal: AbortSignal.timeout(10_000),
  });
  if (!response.ok) throw new Error(`webhook returned ${response.status}`);
};
