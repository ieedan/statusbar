import {
  defineAdapter,
  type AdapterIssue,
  type StatusLevel,
} from "@status-bar/adapter-sdk";

const severity: Record<StatusLevel, number> = {
  unknown: 0,
  operational: 1,
  minor: 2,
  major: 3,
};

/**
 * GCP `status_impact` → normalized level, with `severity` as a tiebreaker.
 * Impact values seen in the feed: SERVICE_OUTAGE, SERVICE_DISRUPTION,
 * SERVICE_INFORMATION. Severity: high | medium | low.
 */
function levelForIncident(statusImpact?: string, sev?: string): StatusLevel {
  switch ((statusImpact ?? "").toUpperCase()) {
    case "SERVICE_OUTAGE":
      return "major";
    case "SERVICE_DISRUPTION":
      return "minor";
    case "SERVICE_INFORMATION":
      return "minor";
  }
  // Fall back to severity when the impact code is missing/unknown.
  switch ((sev ?? "").toLowerCase()) {
    case "high":
      return "major";
    case "medium":
    case "low":
      return "minor";
    default:
      return "unknown";
  }
}

interface GCPProduct {
  title?: string;
  id?: string;
}

interface GCPIncident {
  /** Present once the incident is resolved; absent while it is ongoing. */
  end?: string | null;
  begin?: string;
  external_desc?: string;
  status_impact?: string;
  severity?: string;
  service_name?: string;
  affected_products?: GCPProduct[];
}

export default defineAdapter({
  id: "gcp",
  name: "Google Cloud",
  description: "Google Cloud Platform status feed (incidents.json).",

  // GCP publishes a single fixed JSON feed of recent incidents regardless of the
  // configured URL (which is the human dashboard, used for the "open page" link).
  endpoint: () => "https://status.cloud.google.com/incidents.json",

  parse: (body) => {
    const incidents = JSON.parse(body) as GCPIncident[];

    // The feed includes recently-resolved incidents; an incident is ongoing only
    // while it has no `end` timestamp.
    const active = incidents.filter((i) => !i.end);

    let worst: StatusLevel = "operational";
    const issues: AdapterIssue[] = [];
    for (const incident of active) {
      const level = levelForIncident(incident.status_impact, incident.severity);
      if (severity[level] > severity[worst]) worst = level;

      const title = incident.external_desc?.trim() || "Active incident";
      const products = incident.affected_products ?? [];
      if (products.length === 0) {
        issues.push({
          component: incident.service_name,
          title,
          level,
          startedAt: incident.begin,
        });
      } else {
        for (const product of products) {
          issues.push({
            component: product.title ?? incident.service_name,
            title,
            level,
            startedAt: incident.begin,
          });
        }
      }
    }

    const detail =
      worst === "major"
        ? "Service Outage"
        : worst === "minor"
          ? "Service Disruption"
          : "All Systems Operational";

    return { level: worst, detail, issues };
  },

  suggestedSites: [
    {
      id: "gcp",
      name: "Google Cloud",
      url: "https://status.cloud.google.com",
    },
  ],
});
