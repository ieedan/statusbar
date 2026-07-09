/**
 * Site Status — Adapter SDK
 *
 * An adapter teaches the app how to read one *kind* of status source (e.g. an
 * Atlassian Statuspage, or the AWS Health feed). Adapters are **pure parsers**:
 * the app performs the network request; your adapter only decides which URL to
 * hit and how to turn the response body into a normalized status.
 *
 * That keeps adapters simple, safe (no arbitrary network access), and easy to
 * test — `parse` is a pure function of a string.
 */

/** Normalized severity. The menubar maps these to shapes/colors. */
export type StatusLevel = "operational" | "minor" | "major" | "unknown";

/** A single active issue affecting a site (a Statuspage incident, AWS event…). */
export interface AdapterIssue {
  /** Affected component/service, e.g. "Actions" or "us-east-1". Optional. */
  component?: string;
  /** Short description, e.g. "Delays starting Actions runs". */
  title: string;
  /** Severity of this specific issue. Defaults to the site's overall level. */
  level?: StatusLevel;
  /**
   * When the issue began, as an ISO 8601 string (e.g. "2026-07-09T04:34:24Z").
   * The app shows this as a relative age ("2h ago"). Optional.
   */
  startedAt?: string;
}

/** What `parse` returns. */
export interface StatusResult {
  /** Overall level for the site. */
  level: StatusLevel;
  /** Human-readable summary, e.g. "All Systems Operational". */
  detail: string;
  /** Active issues, if any. Identical titles are de-duplicated by the app. */
  issues?: AdapterIssue[];
}

/** A site this adapter suggests, shown in Settings' "Add service" menu. */
export interface SuggestedSite {
  /** Stable id, e.g. "github". */
  id: string;
  /** Display name, e.g. "GitHub". */
  name: string;
  /** The site's base URL, passed to `endpoint(baseURL)`. */
  url: string;
}

export interface AdapterContext {
  /** The configured site's base URL. */
  baseURL: string;
}

export interface Adapter {
  /** Stable, unique id, e.g. "statuspage". */
  id: string;
  /** Display name shown in Settings. */
  name: string;
  /** One-line description of what this adapter reads. */
  description?: string;
  /**
   * Build the URL to fetch from a site's configured base URL. For a single
   * fixed feed, just return the base URL unchanged.
   */
  endpoint(baseURL: string): string;
  /** Turn the fetched response body into a normalized status. Must be pure. */
  parse(body: string, ctx: AdapterContext): StatusResult;
  /** Sites to offer in the Settings catalog when this adapter is installed. */
  suggestedSites?: SuggestedSite[];
}

declare global {
  // The host (JavaScriptCore) reads the registered adapter from this global.
  // eslint-disable-next-line no-var
  var __STATUSBAR_ADAPTER__: Adapter | undefined;
}

/**
 * Register an adapter with the host. Call this once as your entry point:
 *
 *   export default defineAdapter({ id, name, endpoint, parse });
 */
export function defineAdapter(adapter: Adapter): Adapter {
  (globalThis as { __STATUSBAR_ADAPTER__?: Adapter }).__STATUSBAR_ADAPTER__ =
    adapter;
  return adapter;
}
