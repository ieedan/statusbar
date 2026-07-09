import {
  defineAdapter,
  type AdapterIssue,
  type StatusLevel,
} from "@status-bar/adapter-sdk";

/** Statuspage `indicator`/incident `impact` → normalized level. */
function levelForIndicator(indicator: string): StatusLevel {
  switch (indicator.toLowerCase()) {
    case "none":
      return "operational";
    case "minor":
    case "maintenance":
      return "minor";
    case "major":
    case "critical":
      return "major";
    default:
      return "unknown";
  }
}

/** Statuspage component `status` → normalized level. */
function levelForComponent(status: string): StatusLevel {
  switch (status.toLowerCase()) {
    case "operational":
      return "operational";
    case "degraded_performance":
    case "under_maintenance":
    case "partial_outage":
      return "minor";
    case "major_outage":
      return "major";
    default:
      return "unknown";
  }
}

/** "partial_outage" → "Partial Outage" */
function humanize(token: string): string {
  return token
    .split("_")
    .map((w) => w.charAt(0).toUpperCase() + w.slice(1))
    .join(" ");
}

interface Summary {
  status?: { indicator?: string; description?: string };
  incidents?: Array<{
    name: string;
    impact?: string;
    status?: string;
    started_at?: string;
    created_at?: string;
    updated_at?: string;
    components?: Array<{ name: string; status?: string }>;
  }>;
  components?: Array<{ name: string; status?: string }>;
}

export default defineAdapter({
  id: "statuspage",
  name: "Statuspage",
  description: "Atlassian Statuspage sites (/api/v2/summary.json).",

  endpoint: (baseURL) => baseURL.replace(/\/+$/, "") + "/api/v2/summary.json",

  parse: (body) => {
    const data = JSON.parse(body) as Summary;
    const level = levelForIndicator(data.status?.indicator ?? "");
    const detail = data.status?.description ?? "Unknown";

    const issues: AdapterIssue[] = [];

    // Active incidents are the primary signal — one line per affected component.
    for (const incident of data.incidents ?? []) {
      if (incident.status === "resolved") continue;
      const lvl = levelForIndicator(incident.impact ?? "");
      const startedAt = incident.started_at ?? incident.created_at;
      const updatedAt = incident.updated_at;
      const affected = incident.components ?? [];
      if (affected.length === 0) {
        issues.push({ title: incident.name, level: lvl, startedAt, updatedAt });
      } else {
        for (const component of affected) {
          issues.push({
            component: component.name,
            title: incident.name,
            level: lvl,
            startedAt,
            updatedAt,
          });
        }
      }
    }

    // Fall back to degraded components so a non-green status always explains itself.
    if (issues.length === 0) {
      for (const component of data.components ?? []) {
        if (component.status && component.status !== "operational") {
          issues.push({
            component: component.name,
            title: humanize(component.status),
            level: levelForComponent(component.status),
          });
        }
      }
    }

    return { level, detail, issues };
  },

  suggestedSites: [
    { id: "vercel", name: "Vercel", url: "https://www.vercel-status.com" },
    { id: "github", name: "GitHub", url: "https://www.githubstatus.com" },
    {
      id: "cloudflare",
      name: "Cloudflare",
      url: "https://www.cloudflarestatus.com",
    },
    { id: "anthropic", name: "Anthropic", url: "https://status.anthropic.com" },
    { id: "openai", name: "OpenAI", url: "https://status.openai.com" },
    {
      id: "planetscale",
      name: "PlanetScale",
      url: "https://www.planetscalestatus.com",
    },
    { id: "supabase", name: "Supabase", url: "https://status.supabase.com" },
    { id: "convex", name: "Convex", url: "https://status.convex.dev" },
    { id: "discord", name: "Discord", url: "https://discordstatus.com" },
  ],
});
