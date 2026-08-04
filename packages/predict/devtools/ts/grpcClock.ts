const CLOCK_OBJECT_ID = 6n;

function isClockObjectId(value: unknown): boolean {
    if (typeof value !== "string") return false;
    try {
        return BigInt(value) === CLOCK_OBJECT_ID;
    } catch {
        return false;
    }
}

function clockInputVersion(effects: any): bigint | null {
    const clock = (effects?.unchangedConsensusObjects ?? []).find((object: any) =>
        isClockObjectId(object?.objectId),
    );
    if (!clock) return null;
    if (clock.kind !== "ReadOnlyRoot") {
        throw new Error(`priced transaction Clock input has kind ${String(clock.kind)}`);
    }
    if (clock?.version === null || clock?.version === undefined) {
        throw new Error("priced transaction effects have no read-only Clock input version");
    }
    return BigInt(clock.version);
}

function clockTimestampFromObject(response: any, expectedVersion: bigint): number {
    const object = response?.object;
    if (!object || !isClockObjectId(object.objectId)) {
        throw new Error("Clock version lookup returned the wrong object");
    }
    if (object.version !== expectedVersion) {
        throw new Error(
            `Clock version lookup returned ${String(object.version)}; expected ${expectedVersion}`,
        );
    }
    if (!String(object.objectType ?? "").endsWith("::clock::Clock")) {
        throw new Error(`Clock version lookup returned type ${String(object.objectType)}`);
    }

    const root = object.json?.kind;
    const timestamp =
        root?.oneofKind === "structValue"
            ? root.structValue.fields?.timestamp_ms?.kind
            : undefined;
    if (timestamp?.oneofKind !== "stringValue" || !/^\d+$/.test(timestamp.stringValue)) {
        throw new Error("Clock version lookup returned no u64 timestamp_ms");
    }
    const timestampMs = BigInt(timestamp.stringValue);
    if (timestampMs > BigInt(Number.MAX_SAFE_INTEGER)) {
        throw new Error(`Clock timestamp_ms exceeds JavaScript's safe integer range`);
    }
    return Number(timestampMs);
}

export async function transactionClockTimestampMs(
    effects: any,
    getClockObject: (version: bigint) => Promise<any>,
): Promise<number | null> {
    const version = clockInputVersion(effects);
    if (version === null) return null;
    return clockTimestampFromObject(await getClockObject(version), version);
}
