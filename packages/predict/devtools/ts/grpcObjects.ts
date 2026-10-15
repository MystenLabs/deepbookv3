// Whether one `getObjects` lookup found a live object. The SDK reports a missing object as an
// `ObjectError` that still carries the requested `objectId`, so an `objectId` alone proves
// nothing. A missing or deleted object reads as absent, and any other lookup error throws
// rather than passing for either answer.
export function objectLookupExists(result: unknown): boolean {
    if (result instanceof Error) {
        const reason = (result as { reason?: unknown }).reason;
        if (reason === "notFound" || reason === "deleted") return false;
        throw result;
    }
    if (result === undefined || result === null) return false;
    return typeof (result as { objectId?: unknown }).objectId === "string";
}
