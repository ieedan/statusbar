import {
  defineAdapter,
  type AdapterIssue,
  type StatusLevel,
} from "@statusbar/adapter-sdk";

/**
 * Statuspage `indicator`/incident `impact` → normalized level.
 *
 * Maintenance is planned work the operator scheduled, not something going
 * wrong, so it maps to `operational`: it still gets listed as an issue, but it
 * doesn't light the menubar. Only unplanned trouble earns a warning.
 */
function levelForIndicator(indicator: string): StatusLevel {
  switch (indicator.toLowerCase()) {
    case "none":
    case "maintenance":
      return "operational";
    case "minor":
      return "minor";
    case "major":
    case "critical":
      return "major";
    default:
      return "unknown";
  }
}

/** Statuspage component `status` → normalized level. See `levelForIndicator`
 *  for why `under_maintenance` is not a warning. */
function levelForComponent(status: string): StatusLevel {
  switch (status.toLowerCase()) {
    case "operational":
    case "under_maintenance":
      return "operational";
    case "degraded_performance":
    case "partial_outage":
      return "minor";
    case "major_outage":
      return "major";
    default:
      return "unknown";
  }
}

/** Pages listing at least this many components (see `parse`) are too large for
 *  per-component statuses to mean "something is down" without an incident. */
const NOISY_PAGE_COMPONENTS = 100;

/** "partial_outage" → "Partial Outage" */
function humanize(token: string): string {
  return token
    .split("_")
    .map((w) => w.charAt(0).toUpperCase() + w.slice(1))
    .join(" ");
}

interface Component {
  id?: string;
  name: string;
  status?: string;
  /** Last time Statuspage touched this component — in practice, when its
   *  status last changed. Absent on some hand-rolled implementations. */
  updated_at?: string;
  /** True for a *group* header, whose status is a rollup of its children. */
  group?: boolean;
  /** Set on a child to the id of the group it belongs to. */
  group_id?: string | null;
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
  components?: Component[];
}

export default defineAdapter({
  id: "statuspage",
  name: "Statuspage",
  description: "Atlassian Statuspage sites (/api/v2/summary.json).",

  endpoint: (baseURL) => baseURL.replace(/\/+$/, "") + "/api/v2/summary.json",

  parse: (body) => {
    const data = JSON.parse(body) as Summary;
    const reportedLevel = levelForIndicator(data.status?.indicator ?? "");
    const reportedDetail = data.status?.description ?? "Unknown";

    const issues: AdapterIssue[] = [];
    let level = reportedLevel;
    let detail = reportedDetail;

    // Active incidents are the primary signal — one line per affected component.
    for (const incident of data.incidents ?? []) {
      if (incident.status === "resolved") continue;
      let lvl = levelForIndicator(incident.impact ?? "");
      // A "monitoring" incident has had its fix deployed and is only being
      // watched for recurrence — the site's own top-level indicator has usually
      // already returned to green. Cap it at "minor" so a recovering outage
      // doesn't keep the overall status pinned at "major" after the impact is
      // effectively over. The incident still shows in the menu, just demoted.
      if (incident.status === "monitoring" && lvl === "major") {
        lvl = "minor";
      }
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
      const components = data.components ?? [];
      // A group header's status is just a rollup of its children, and
      // summary.json lists the children too — so emitting the group as well
      // reports the same degradation twice ("Africa" plus each of its cities).
      // Keep the leaves, which name what is actually degraded.
      const parents = new Set(
        components.map((c) => c.group_id).filter((id): id is string => !!id),
      );
      const leaves = components.filter(
        (c) => !(c.group && c.id && parents.has(c.id)),
      );

      // Huge pages are a different animal. Cloudflare lists ~340 edge
      // locations next to its ~130 real services; a few dozen sit in
      // `major_outage` or `degraded_performance` at any moment, some for
      // months, and Statuspage rolls them all into the top-level indicator —
      // so the site reads "Partial System Outage" while Cloudflare's own page
      // says "No known service issues". With no active incident, statuses from
      // a list that long are standing infrastructure noise, not an outage (a
      // real one gets an incident). So they only get summarised, at
      // `operational`, and don't set the site's level.
      if (leaves.length >= NOISY_PAGE_COMPONENTS) {
        const affected = leaves.filter(
          (c) =>
            c.status &&
            c.status !== "operational" &&
            c.status !== "under_maintenance",
        );
        level = "operational";
        detail = "All Systems Operational";
        if (affected.length > 0) {
          issues.push({
            title: `${affected.length} of ${leaves.length} components not fully operational`,
            level: "operational",
          });
        }
        return { level, detail, issues };
      }

      for (const component of components) {
        if (component.group && component.id && parents.has(component.id)) {
          continue;
        }
        if (component.status && component.status !== "operational") {
          issues.push({
            component: component.name,
            title: humanize(component.status),
            level: levelForComponent(component.status),
            // Pass the component's own timestamp through so these get aged like
            // any other issue. Large pages list standing infrastructure —
            // Cloudflare publishes ~340 edge locations, a handful of which are
            // always rerouted or under maintenance — and without a timestamp
            // that permanent background noise reads as a live outage forever.
            // With one, the app demotes anything quiet for days into the
            // low-priority submenu, which is how Cloudflare's own page now
            // reports it: "All systems operational", locations listed apart.
            updatedAt: component.updated_at,
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
    { id: "cursor", name: "Cursor", url: "https://status.cursor.com" },
    { id: "discord", name: "Discord", url: "https://discordstatus.com" },
  ],
});
