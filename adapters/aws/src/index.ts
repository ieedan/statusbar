import {
  defineAdapter,
  type AdapterIssue,
  type StatusLevel,
} from "@status-bar/adapter-sdk";

/**
 * AWS numeric event status → normalized level.
 * 1 = informational, 2 = degraded performance, 3 = service disruption.
 * (0, if it ever appears in the current-events feed, is operational.)
 */
function levelForCode(code: string): StatusLevel {
  switch (code.trim()) {
    case "0":
      return "operational";
    case "1":
    case "2":
      return "minor";
    case "3":
      return "major";
    default:
      return "minor";
  }
}

const severity: Record<StatusLevel, number> = {
  unknown: 0,
  operational: 1,
  minor: 2,
  major: 3,
};

interface AWSEvent {
  status: string;
  summary?: string;
  service_name?: string;
  date?: string; // epoch seconds, as a string
}

/** Epoch-seconds string → ISO 8601, or undefined if unparseable. */
function isoFromEpochSeconds(seconds?: string): string | undefined {
  if (!seconds) return undefined;
  const n = Number(seconds);
  if (!Number.isFinite(n)) return undefined;
  return new Date(n * 1000).toISOString();
}

export default defineAdapter({
  id: "aws",
  name: "AWS Health",
  description: "AWS Health current-events feed.",

  // AWS publishes a single fixed JSON feed regardless of the configured URL
  // (which is the human dashboard, used for the "open page" link). The host
  // transcodes the feed's UTF-16 body to UTF-8 before calling parse.
  endpoint: () => "https://health.aws.amazon.com/public/currentevents",

  parse: (body) => {
    const events = JSON.parse(body) as AWSEvent[];

    let worst: StatusLevel = "operational";
    const issues: AdapterIssue[] = [];
    for (const event of events) {
      const level = levelForCode(String(event.status));
      if (severity[level] > severity[worst]) worst = level;
      issues.push({
        component: event.service_name,
        title: event.summary ?? "Active event",
        level,
        startedAt: isoFromEpochSeconds(event.date),
      });
    }

    const detail =
      worst === "major"
        ? "Major Service Outage"
        : worst === "minor"
          ? "Service Degradation"
          : "All Systems Operational";

    return { level: worst, detail, issues };
  },

  suggestedSites: [
    {
      id: "aws",
      name: "AWS",
      url: "https://health.aws.amazon.com/health/status",
    },
  ],
});
