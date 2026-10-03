export function createAlerter(webhookUrl, cooldownMs = 15 * 60_000, now = Date.now, fetchImpl = fetch) {
    const lastSent = new Map();
    return async (key, message) => {
        console.error(`[alert] ${key}: ${message}`);
        const previous = lastSent.get(key);
        if (previous !== undefined && now() - previous < cooldownMs)
            return;
        lastSent.set(key, now());
        if (!webhookUrl)
            return;
        try {
            const response = await fetchImpl(webhookUrl, {
                method: 'POST',
                headers: { 'content-type': 'application/json' },
                body: JSON.stringify({ text: `[perp-feeds] ${message}`, content: `[perp-feeds] ${message}` }),
                signal: AbortSignal.timeout(10_000),
            });
            // A 2xx means the webhook took it, not that anyone read it; a non-2xx means nobody will.
            if (!response.ok)
                console.error(`[alert] webhook returned ${response.status} for ${key}`);
        }
        catch (error) {
            console.error(`[alert] webhook failed for ${key}: ${error.message}`);
        }
    };
}
