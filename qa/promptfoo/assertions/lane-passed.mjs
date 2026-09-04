export default function lanePassed(output) {
  try {
    const evidence = JSON.parse(output);
    const valid =
      evidence?.schemaVersion === 1 &&
      typeof evidence.lane === "string" &&
      evidence.lane.length > 0 &&
      evidence.status === "passed" &&
      evidence.exitCode === 0 &&
      /^[a-f0-9]{40}$/.test(evidence.commit) &&
      ["clean", "dirty"].includes(evidence.workspaceState) &&
      /^[a-f0-9]{64}$/.test(evidence.workspaceHash) &&
      /^[a-f0-9]{64}$/.test(evidence.evidenceHash) &&
      Number.isFinite(evidence.durationMs) &&
      evidence.durationMs >= 0;
    return {
      pass: valid,
      score: valid ? 1 : 0,
      reason: valid
        ? `${evidence.lane} passed in ${evidence.durationMs} ms`
        : `${evidence?.lane || "unknown lane"} did not produce passing deterministic evidence: ${evidence?.summary || "no summary"}`,
    };
  } catch (error) {
    return { pass: false, score: 0, reason: `Invalid evidence JSON: ${error.message}` };
  }
}
