import Foundation

/// A built-in list of well-known services. Used to seed a fresh install and to
/// populate the "Add service" menu in Settings, so common services can be added
/// with one click instead of typing a URL.
public enum ServiceCatalog {
    public static let all: [SiteConfig] = [
        SiteConfig(id: "vercel", name: "Vercel", kind: .statuspage,
                   url: URL(string: "https://www.vercel-status.com")!),
        SiteConfig(id: "github", name: "GitHub", kind: .statuspage,
                   url: URL(string: "https://www.githubstatus.com")!),
        SiteConfig(id: "cloudflare", name: "Cloudflare", kind: .statuspage,
                   url: URL(string: "https://www.cloudflarestatus.com")!),
        SiteConfig(id: "aws", name: "AWS", kind: .awsHealth,
                   url: URL(string: "https://health.aws.amazon.com/public/currentevents")!),
        SiteConfig(id: "anthropic", name: "Anthropic", kind: .statuspage,
                   url: URL(string: "https://status.anthropic.com")!),
        SiteConfig(id: "openai", name: "OpenAI", kind: .statuspage,
                   url: URL(string: "https://status.openai.com")!),
        SiteConfig(id: "planetscale", name: "PlanetScale", kind: .statuspage,
                   url: URL(string: "https://www.planetscalestatus.com")!),
        SiteConfig(id: "supabase", name: "Supabase", kind: .statuspage,
                   url: URL(string: "https://status.supabase.com")!),
        SiteConfig(id: "convex", name: "Convex", kind: .statuspage,
                   url: URL(string: "https://status.convex.dev")!),
        SiteConfig(id: "discord", name: "Discord", kind: .statuspage,
                   url: URL(string: "https://discordstatus.com")!),
    ]

    /// Catalog entries whose `id` isn't already present in `existing`.
    public static func available(excluding existing: [SiteConfig]) -> [SiteConfig] {
        let taken = Set(existing.map(\.id))
        return all.filter { !taken.contains($0.id) }
    }
}
